#!/bin/bash

# Kucoin Exchange - variables & functions
# ----------------------------------------
# API documentation:  https://www.kucoin.com/docs/beginners/introduction

# API rate limiting: 2000 public api calls per 30 seconds & 4000 spot api calls per 30 seconds
	# therefore using lowest rate limit of 2000 is ~66 calls per second
	# bctb should average 10 calls per loop, so we could set sleep to 1, but recommend rate_limit_sleep="5" in config

# Variables
market_name="$base_currency-$quote_currency"	# must be upper case in config - TODO: should validate or force upper from config import
sell_amount_requires_fee="false"	# set to false if exchange handles fee math on sell orders

# Functions

private_api_query() {
# HTTP 1.1 forced for kucoin as i was receiving HTTP status 000 errors when http2 was used...
# -binary (utf-8 encoding) required for hmac with kucoin
	endpoint="/api/v1/$1"	# api version included in endpoint as it's needed in pre_sign variable
	http_method="$2"
	body="$3"
	[ -z "$3" ] && body=""	# content hash needs empty string for requests with no body
	url="https://api.kucoin.com$endpoint"
	private_timestamp="$(date +%s%3N)"
	pre_sign="$private_timestamp$http_method$endpoint$body"
	hmacsignature_encoded="$(echo -n "$pre_sign" | openssl dgst -sha256 -hmac "$api_secret" -binary | sed 's/^.*= //' | base64)"
	encrypted_passphrase="$(echo -n "$api_passphrase" | openssl dgst -sha256 -hmac "$api_secret" -binary | sed 's/^.*= //' | base64)"
	
	if [ "$http_method" = "POST" ]; then
		#request="--request $http_method --data-raw $body"	# passing empty body causes issues with http status code, so only include if POST method
			# passing body in request variable was causing issues with content hash, so split POST and other request methods
		curl \
		--http1.1 \
		--silent \
		--write-out "\n%{http_code}\n" \
		--header "Content-Type: application/json" \
		--header "KC-API-KEY: $api_key" \
		--header "KC-API-TIMESTAMP: $private_timestamp" \
		--header "KC-API-PASSPHRASE: $encrypted_passphrase" \
		--header "KC-API-KEY-VERSION: 2" \
		--header "KC-API-SIGN: $hmacsignature_encoded" \
		--url "$url" \
		--request "$http_method" \
		--data-raw "$body"
	else
		curl \
		--http1.1 \
		--silent \
		--write-out "\n%{http_code}\n" \
		--header "Content-Type: application/json" \
		--header "KC-API-KEY: $api_key" \
		--header "KC-API-TIMESTAMP: $private_timestamp" \
		--header "KC-API-PASSPHRASE: $encrypted_passphrase" \
		--header "KC-API-KEY-VERSION: 2" \
		--header "KC-API-SIGN: $hmacsignature_encoded" \
		--url "$url" \
		--request "$http_method"
	fi
}

public_api_query() {
	endpoint="$1"
	url="https://api.kucoin.com/api/v1/$endpoint"

	curl \
	--silent \
	--write-out "\n%{http_code}\n" \
	--header "Content-Type: application/json" \
	--request "GET" \
	--url "$url"
}

api_response_parser() {
	response="$1"
	calling_function="$2"
	declare -i http_status	# only allow integer for http status code
	http_status="$(tail -n 1 "$response")" # last line contains http_code from cURL
	if [ "$http_status" -ge 100 ] && [ "$http_status" -lt 299 ]; then
		echo "$calling_function api call successful - http status code: $http_status"
		failed_error_count="1"	# reset counter
		unexpected_error_count="1"	# reset counter
	elif [ "$http_status" -gt 399 ]; then
		rsp_error_code="$(grep '{' "$response" | jq -r .code)"
		rsp_error_detail="$(grep '{' "$response" | jq -r .msg)"
		echo "$calling_function api call failed"
		echo "api error code: $rsp_error_code"
		echo "api error detail: $rsp_error_detail"
		echo "http status code: $http_status"
		send_email "ERROR: $calling_function api call failed" "api rsp: $rsp_error_code \napi error: $rsp_error_detail \nhttp status code: $http_status" "$response"
		let failed_error_count=failed_error_count+1
		failed_error_sleep_time="$(echo "30 * $failed_error_count" | bc -l)" # increase sleep time on consecutive errors
		sleep "$failed_error_sleep_time"	# sleep in case of API issues
		return 1	# restart main trading loop
	else
		rsp_error_code="$(grep '{' "$response" | jq -r .code)"
		rsp_error_detail="$(grep '{' "$response" | jq -r .detail)"
		echo "$calling_function api call unexpected response"
		echo "api error code: $rsp_error_code"
		echo "api error detail: $rsp_error_detail"
		echo "http status code: $http_status"
		echo "posssible network issues or API outage"
		send_email "ERROR: $calling_function api call unexpected response" "api rsp: $rsp_error_code \napi error: $rsp_error_detail \nhttp status code: $http_status" "$response"
		let unexpected_error_count=unexpected_error_count+1
		unexpected_error_sleep_time="$(echo "60 * $unexpected_error_count" | bc -l)" # increase sleep time on consecutive errors
		sleep "$unexpected_error_sleep_time"	# sleep in case of API issues
		return 1	# restart main trading loop
	fi
	#TODO: standardise common errors here and push metrics to influxdb (e.g. throttled by rate limit)
}

# Public API calls

# tested
#https://www.kucoin.com/docs/rest/spot-trading/market-data/get-ticker
get_market() {
	market="$(mktemp "$tmp_file_template")"
	public_api_query "market/orderbook/level1?symbol=$market_name" > "$market"	#https://www.kucoin.com/docs/rest/spot-trading/market-data/get-ticker
	api_response_parser "$market" "get_market" || return 1
	market_ask="$(grep '{' "$market" | jq -r '.data.bestAsk' | xargs printf "%.8f")"
	market_bid="$(grep '{' "$market" | jq -r '.data.bestBid' | xargs printf "%.8f")"
	market_last_price="$(grep '{' "$market" | jq -r '.data.price' | xargs printf "%.8f")"

	api_value_validator "number" "$market_ask" "get_market ask" || return 1
	api_value_validator "number" "$market_bid" "get_market bid" || return 1

	## volume doesn't appear to be used atm via get_market function, so not wasting time setting this up for KuCoin
	#market_summary="$(mktemp "$tmp_file_template")"
	#public_api_query "markets/$market_name/summary" > "$market_summary"	#https://bittrex.github.io/api/v3#operation--markets--marketSymbol--summary-get
	#api_response_parser "$market_summary" "get_market_summary" || return 1
	#market_volume="$(grep '{' "$market_summary" | jq -r '.volume' | xargs printf "%.8f")"	# base (alt coin) volume
	#market_base_volume="$(grep '{' "$market_summary" | jq -r '.quoteVolume' | xargs printf "%.8f")"	# quote (BTC) volume
	
	#market_open_buy_orders="$(grep '{' "$market_summary" | jq -r '.result[].OpenBuyOrders' | xargs printf "%.8f")"
	#market_open_buy_orders="$(grep '{' "$market_summary" | jq -r '.result[].OpenSellOrders' | xargs printf "%.8f")"
}

# tested
# https://www.kucoin.com/docs/rest/spot-trading/market-data/get-all-tickers
get_markets() {
	# used to decide on market to trade based on market base volumes
	markets="$(mktemp "$tmp_file_template")"
	markets_filtered="$(mktemp "$tmp_file_template")"
	markets_blacklist_cmd="$(mktemp "$tmp_file_template")"
	public_api_query "market/allTickers" > "$markets"
	api_response_parser "$markets" "get_markets" || return 1

	# filter out blacklisted and non-BTC markets
	blacklist_manager "list" || return 1
	if [ "$blacklist_empty" = "true" ]; then
		grep '{' "$markets" | jq -r --arg quote_currency "-$quote_currency" '.data.ticker[] | select(.symbol | contains($quote_currency))' > "$markets_filtered"
	else
		# hack to workaround jq not accepting commands stored in variables
		echo "grep '{' $markets | jq -r '.data.ticker[] | select(.symbol | contains(\"-$quote_currency\")) | select(.symbol | $blacklist_contains | not)'" > "$markets_blacklist_cmd"
		bash "$markets_blacklist_cmd" > "$markets_filtered"
	fi

	previous_market_name="$market_name"
	market_volume="$(jq -s -r 'sort_by(.volValue | tonumber) | .[-1] | .volValue' "$markets_filtered" | xargs printf "%.8f")"	# quote (BTC) volume
	market_base_volume="$(jq -s -r 'sort_by(.vol | tonumber) | .[-1] | .vol' "$markets_filtered" | xargs printf "%.8f")"	# base (alt coin) volume
	#market_buy_base_volume="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .BuyBaseVolume' "$markets_filtered" | xargs printf "%.8f")"
	#market_sell_base_volume="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .SellBaseVolume' "$markets_filtered" | xargs printf "%.8f")"
	market_name="$(jq -s -r 'sort_by(.volValue | tonumber) | .[-1] | .symbol' "$markets_filtered")"	# select market with largest base volume
	base_currency="$(echo "$market_name" | awk -F '-' '{print $1}')"
}

# tested
# https://www.kucoin.com/docs/rest/spot-trading/market-data/get-symbols-list
# https://www.kucoin.com/docs/rest/spot-trading/market-data/get-all-tickers
get_trade_pairs() {
	trade_pairs="$(mktemp "$tmp_file_template")"
	public_api_query "symbols" > "$trade_pairs"
	api_response_parser "$trade_pairs" "get_trade_pairs" || return 1
	market_fees="$(mktemp "$tmp_file_template")"
	public_api_query "market/allTickers" > "$market_fees"
	api_response_parser "$market_fees" "get_market_fees" || return 1
	market_makerRate="$(grep '{' "$market_fees" | jq -r --arg market_name "$market_name" '.data.ticker[] | select(.symbol==$market_name) | .makerFeeRate' | tr -d '"')"
	trade_fee="$(echo "$market_makerRate * 100" | bc -l | xargs printf "%.2f")"
	min_trade_size="$(grep '{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.data[] | select(.symbol==$market_name) | .baseMinSize')"
	get_market
	min_base_trade="$(echo "$min_trade_size * $market_last_price" | bc -l | xargs printf "%.8f")"
	trade_pair_status="$(grep '{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.data[] | select(.symbol==$market_name) | .enableTrading')"
	trade_pair_price_increment="$(grep '{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.data[] | select(.symbol==$market_name) | .priceIncrement')"	#kucoin uses price increments for trade amounts
	trade_pair_base_increment="$(grep '{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.data[] | select(.symbol==$market_name) | .baseIncrement')"	#kucoin uses base increments for trade amounts
	# check if trade fee has changed from expected amount
	if [ "$(echo "$trade_fee > $expected_trade_fee" | bc -l)" -eq 1 ]; then
		echo "WARN: Trade fee has increased!"
		echo "Expected fee: $expected_trade_fee"
		echo "Current fee: $trade_fee"
		send_email "WARN: Trade fee has increased!" "Expected fee: $expected_trade_fee \nCurrent fee: $trade_fee"
	elif [ "$(echo "$trade_fee < $expected_trade_fee" | bc -l)" -eq 1 ]; then
		echo "INFO: Trade fee has decreased! Expected ($expected_trade_fee), but current fee is ($trade_fee). More profit!!"
	fi
	# check trade pair status
	if [ "$trade_pair_status" != "true" ]; then
		echo "WARN: $market_name status is $trade_pair_status"
		echo "Adding $market_name to blacklist"
		blacklist_manager "add" "$market_name" "1" "bad market status" || return 1
		return 1
	fi
}

# GetMarketOrders - not used, so not ported to kucoin
#get_market_orders() {
	#market_orders_limit="10"	# number of open buy and sell market orders to retrieve
	#market_orders="$(mktemp "$tmp_file_template")"
	#market_name_get="$(echo "$market_name" | tr / _)"
	#public_api_query GetMarketOrders "$market_name_get" "$market_orders_limit" > "$market_orders"
	#api_response_parser "$market_orders" "get_market_orders" || return 1
	#market_orders_buy="$(grep '{' "$market_orders" | jq -r '.Data.Buy[].Price')"
	#market_orders_sell="$(grep '{' "$market_orders" | jq -r '.Data.Sell[].Price')"
	#market_buy_average="$(echo "$market_orders_buy" | jq -r -s 'add/length' | xargs printf "%.8f")"
	#market_sell_average="$(echo "$market_orders_sell" | jq -r -s 'add/length' | xargs printf "%.8f")"
#}

# tested
# https://www.kucoin.com/docs/rest/spot-trading/market-data/get-trade-histories
get_market_history() {
	# add all prices from a given time period and divide by the number of prices to work out the average
	#market_history_hours="24"	# currently not used by kucoin - API limits to the last 100 results. This limits MA periods to 100 max when using trades instead of candles. Need to start tracking history ourselves (might be able to leverage data collected for back-testing?)
	market_history="$(mktemp "$tmp_file_template")"
	public_api_query "market/histories?symbol=$market_name" > "$market_history"
	api_response_parser "$market_history" "get_market_history" || return 1
	market_history_prices="$(grep '{' "$market_history" | jq -r '.data[].price')"
	market_history_trade_count="$(echo "$market_history_prices" | wc -l)"
	if [ "$market_history_trade_count" -lt "$sma_period" ] || [ "$market_history_trade_count" -lt "$ltma_period" ]; then
		echo "Error: Trade count ($market_history_trade_count) is less than expected SMA period ($sma_period) or LTMA period ($ltma_period)"
		send_email "Error: Trade count not met!" "Trade count: $market_history_trade_count \nSMA period config: $sma_period \nLTMA period config: $ltma_period" "$market_history"
		return 1	# avoid incorrect averages when market count not met
	fi
}

# tested
# https://www.kucoin.com/docs/rest/spot-trading/market-data/get-klines
get_candles() {
	candles="$(mktemp "$tmp_file_template")"
	# candleInterval: string 1min, 3min, 5min, 15min, 30min, 1hour, 2hour, 4hour, 6hour, 8hour, 12hour, 1day, 1week, 1month
	# convert candles_interval minutes to kucoin tickInterval param (rounds up)
	if [ "$candles_interval" -le 1 ]; then
		dataGroup="1min"		# 1 minute
	elif [ "$candles_interval" -le 3 ]; then
		dataGroup="3min"		# 3 minutes
	elif [ "$candles_interval" -le 5 ]; then
		dataGroup="5min"		# 5 minutes
	elif [ "$candles_interval" -le 15 ]; then
		dataGroup="15min"		# 15 minutes
	elif [ "$candles_interval" -le 30 ]; then
		dataGroup="30min"		# 30 minutes
	elif [ "$candles_interval" -le 60 ]; then
		dataGroup="1hour"		# 1 hour
	elif [ "$candles_interval" -le 120 ]; then
		dataGroup="2hour"		# 2 hour
	elif [ "$candles_interval" -le 240 ]; then
		dataGroup="4hour"		# 4 hour
	elif [ "$candles_interval" -le 360 ]; then
		dataGroup="6hour"		# 6 hour
	elif [ "$candles_interval" -le 480 ]; then
		dataGroup="8hour"		# 8 hour
	elif [ "$candles_interval" -le 720 ]; then
		dataGroup="12hour"		# 12 hour
	elif [ "$candles_interval" -le 1440 ]; then
		dataGroup="1day"		# 1 day
	elif [ "$candles_interval" -le 10080 ]; then
		dataGroup="1week"		# 1 week
	elif [ "$candles_interval" -le 322560 ]; then
		dataGroup="1month"		# 1 month
	else
		echo "Error: Unknown candles interval ($candles_interval) for current exchange"
		send_email "Error: Get candles interval!" "Unknown candles interval ($candles_interval) for current exchange" "$candles"
		return 1
	fi

	#candleType="trade" # trade | midpoint - not used by kucoin

# TODO- limited to 100 results by default, need to use start and end times to pull more data...
	#epoch_yesterday="$(date -d "yesterday" +%s)"	#24 hours ago

	public_api_query "market/candles?type=$dataGroup&symbol=$market_name" > "$candles"
	api_response_parser "$candles" "get_candles" || return 1

	candles_open_list="$(grep '{' "$candles" | jq -r '.data[] | .[1]')"
	candles_high_list="$(grep '{' "$candles" | jq -r '.data[] | .[3]')"
	candles_low_list="$(grep '{' "$candles" | jq -r '.data[] | .[4]')"
	candles_close_list="$(grep '{' "$candles" | jq -r '.data[] | .[2]')"

	#How to filter candles - head when newest first, tail when newest last
	candles_filter="head"	# Kucoin returns newest candles first
}


# Private API calls

# tested
#https://www.kucoin.com/docs/rest/account/basic-info/get-account-list-spot-margin-trade_hf
get_balance() {
	currency="$1"
	#balance_currency="currency=$currency"
	balance="$(mktemp "$tmp_file_template")"
	if [ -z "$currency" ]; then
		private_api_query "accounts" GET > "$balance"	# get_balance without currency doesn't appear to be used anywhere atm
	else
		private_api_query "accounts?currency=$currency" GET > "$balance"
	fi
### api value validator should probably be used here, but how to determine if the balance is truely zero?
	api_response_parser "$balance" "get_balance" || return 1
	kucoin_balance="$(grep '{' "$balance" | jq -r '.data[] | select(.type=="trade") | .available')"	# filter on trade accounts to avoid picking up funding accounts
	# handle empty balances with some exchanges
	if [ "$kucoin_balance" = "" ]; then
		available_balance="0"
	elif [ "$kucoin_balance" = "null" ]; then
		available_balance="0"
	else
		available_balance="$(echo "$kucoin_balance" | xargs printf "%.8f")"
	fi
}

# tested
# https://www.kucoin.com/docs/rest/spot-trading/orders/get-order-list
get_open_orders() {
	open_orders="$(mktemp "$tmp_file_template")"
	private_api_query "orders?status=active&symbol=$market_name" GET > "$open_orders"
	api_response_parser "$open_orders" "get_open_orders" || return 1
	##### need to handle multiple open orders?
	open_order_check="$(grep '{' "$open_orders" | jq -r '.data.items[]')"
	if [ -z "$open_order_check" ]; then 	#TODO: open orders sometimes null after buy on kucoin - need to investigate
		no_open_orders="true"
		echo "No open order(s) for $market_name market"
	else
		no_open_orders="false"
		echo "Open order(s) found for $market_name market"
		open_order_id="$(grep '{' "$open_orders" | jq -r '.data.items[].id')"
		open_order_amount="$(grep '{' "$open_orders" | jq -r '.data.items[].size')"
		open_order_amount_filled="$(grep '{' "$open_orders" | jq -r '.data.items[].dealSize')"
		open_order_amount_remaining="$(echo "$last_trade_amount - $open_order_amount_filled" | bc -l | xargs printf "%.8f")"
	fi
}

# tested
# https://www.kucoin.com/docs/rest/spot-trading/orders/place-order
	# kucoin requires order amounts in pre-defined increments (priceIncrement in https://www.kucoin.com/docs/rest/spot-trading/market-data/get-symbols-list)
		# only implemented on buy orders so far as sell is almost always maximum in my use case
submit_trade_order() {
	submit_trade="$(mktemp "$tmp_file_template")"
	order_uuid="$(uuidgen)"	# requires uuid-runtime package - uuid required by kucoin exchange
	if [ "$trade_type" = "Buy" ]; then
		# align buy amount with price increment requirement on kucoin
		trade_amount_rounding="$(echo "$trade_amount / $trade_pair_base_increment" | bc -l | xargs printf "%.0f")"	# round up increment to int
		trade_amount="$(echo "$trade_amount_rounding * $trade_pair_base_increment - $trade_pair_base_increment" | bc -l)" # multiply and then subtract by increment without xargs
		trade='{"symbol": "'"$market_name"'","type": "limit","size": "'"$trade_amount"'","price": "'"$trade_rate"'","timeInForce": "GTC","side": "buy","clientOid": "'"$order_uuid"'"}'
		private_api_query orders POST "$trade" > "$submit_trade"
	elif [ "$trade_type" = "Sell" ]; then
		#if [ "$ma_sell" = "maximum" ]; then
			# use market order to sell entire balance at market rate - this may incur slipage!!!
		#	trade='{"marketSymbol": "'"$market_name"'","type": "MARKET","timeInForce": "GOOD_TIL_CANCELLED","direction": "SELL"}'
		#	private_api_query orders POST "$trade" > "$submit_trade"
		#else
			# use limit order
			trade='{"symbol": "'"$market_name"'","type": "limit","size": "'"$trade_amount"'","price": "'"$trade_rate"'","timeInForce": "GTC","side": "sell","clientOid": "'"$order_uuid"'"}'
			private_api_query orders POST "$trade" > "$submit_trade"
		#fi
	fi
	api_response_parser "$submit_trade" "submit_trade_order" || return 1
	last_order_id="$(grep '{' "$submit_trade" | jq -r '.data.orderId')"
	last_trade_type="$trade_type"	
	last_trade_cost="$trade_total_cost"
	#last_trade_rate="$trade_rate"	# not used 
	last_trade_amount="$trade_amount"
	#filled_orders="$(grep '{' "$submit_trade" | jq -r '.fillQuantity')"	# not available in kucoin without further api calls
	#filled_orders_count="0"	# TBC if supported on kucoin

	api_value_validator "null" "$last_order_id" "submit_trade_order trade id" || return 1 # workaround kucoin api returning 200 status code for invalid quantity increment error 400100"

	echo "$trade_type trade submitted!"
	echo "Trade Id: $last_order_id"
	echo "Trade amount: $last_trade_amount"
	echo "Trade cost: $last_trade_cost"
	#echo "Filled orders: $filled_orders"
	#if [ "$filled_orders" -gt 0 ]; then 	### THIS ISN'T WORKING AS IT'S A FLOAT INSTEAD OF INTEGER
	#	echo "Trade filled :)"
	#else
	#	echo "Trade open..."
	#fi
	# increase counter for consecutive trades
	if [ "$trade_type" = "Buy" ]; then
		let buy_count=buy_count+1
		old_sell_count="$sell_count"
		sell_count="0"	#reset 
		low_sell_balance="false"	# remove low balance restriction
	elif [ "$trade_type" = "Sell" ]; then
		let sell_count=sell_count+1
		old_buy_count="$buy_count"
		buy_count="0"	#reset
		low_buy_balance="false"		# remove low balance restriction
	fi
	send_email "$trade_type trade submitted - $market_name" "Trade type: $trade_type \nTrade Id: $last_order_id \nTrade rate: $trade_rate $quote_currency\nTrade amount: $trade_amount $base_currency\nFilled orders: $filled_orders"
}

# tested
# https://www.kucoin.com/docs/rest/spot-trading/orders/cancel-order-by-orderid
cancel_trade_order() {
	order_id="$1"
	cancel_trade="$(mktemp "$tmp_file_template")"
	private_api_query "orders/$order_id" DELETE > "$cancel_trade"
	api_response_parser "$cancel_trade" "cancel_trade_order" || return 1
	cancel_trade_data="$(grep '{' "$cancel_trade" | jq -r '.data.cancelledOrderIds[]')"
	echo "Cancelled order data: $cancel_trade_data"
	# roll back counter for consecutive trades - this doesn't handle partially filled orders...
	if [ "$last_trade_type" = "Buy" ]; then
		let buy_count=buy_count-1
		sell_count="$old_sell_count"	#restore
	elif [ "$last_trade_type" = "Sell" ]; then
		let sell_count=sell_count-1
		buy_count="$old_buy_count"	#restore
	fi
	send_email "Trade cancelled - $market_name" "Order Id: $order_id \nCancel data: $cancel_trade_data \nOrder amount: $open_order_amount \nOrder amount remaining: $open_order_amount_remaining \nOrder amount filled: $open_order_amount_filled"
}

# tested
# https://www.kucoin.com/docs/rest/spot-trading/orders/get-order-list
get_trade_history() {
	count="$1"	# not used in kucoin - hardcoded to last order [0] #TODO - add count support
	#past_trades="market=$market_name"
	trade_history="$(mktemp "$tmp_file_template")"
	private_api_query "orders?status=done&symbol=$market_name&type=limit" GET > "$trade_history" # Only pull "done" status orders to avoid picking up open orders
	api_response_parser "$trade_history" "get_trade_history" || return 1
	emtpy_history="$(grep '{' "$trade_history" | jq -r '.data.items[0]')"	# items array may not be present if a single order exists...
	if [ "$emtpy_history" = "" ] || [ "$emtpy_history" = "null" ]; then
		#Kucoin only returns results for done orders for the last 7 days, so we need to go back in time to find older orders. History is kept for 6 months.
		echo "no trade history found in last 7 days (kucoin max history window) - looking back further"
		no_history="true"
		kucoin_history_days="7"
		while [ "$kucoin_history_days" -lt "$max_position_age" ] && [ "$no_history" = "true" ]; do
			# increment history days by 7 to find older orders up to max position age
			let kucoin_history_days=kucoin_history_days+7
			kucoin_history_start_millis="$(date --date="$kucoin_history_days days ago" +%s%3N)"
			private_api_query "orders?status=done&symbol=$market_name&type=limit&startAt=$kucoin_history_start_millis" GET > "$trade_history"
			api_response_parser "$trade_history" "get_trade_history" || return 1
			emtpy_history="$(grep '{' "$trade_history" | jq -r '.data.items[0]')"	#TODO: should check totalNum instead {"code":"200000","data":{"currentPage":1,"pageSize":50,"totalNum":0,"totalPage":0,"items":[]}}
			if [ "$emtpy_history" = "" ] || [ "$emtpy_history" = "null" ]; then
				no_history="true"
				echo "no history found up-to $kucoin_history_days days ago"
			else
				no_history="false"
				echo "trade history found up-to $kucoin_history_days days ago"
			fi
		done
	else
		no_history="false"
	fi
	if [ "$no_history" = "false" ]; then
		# need to check if the order has been cancelled using select(.cancelExist==false) | pass back to jq to slurp into an array
		trade_history_id="$(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].id')"
		trade_history_market="$(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].symbol')"
		trade_history_base_currency="$(echo "$trade_history_market" | awk -F '-' '{print $1}')"
		trade_history_type_kucoin="$(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].side')"
		trade_history_cost="$(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].dealFunds' | xargs printf "%.8f")"
		trade_history_rate="$(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].price' | xargs printf "%.8f")"
		trade_history_quantity="$(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].size' | xargs printf "%.8f")"
		#trade_history_amount="$(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].dealSize' | jq -r -s 'add' | xargs printf "%.8f")" # sum for split filled orders
		trade_history_amount="$(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].dealSize' | xargs printf "%.8f")"
		trade_history_timestamp_kucoin="$(echo $(grep '{' "$trade_history" | jq -r '.data.items[] | select(.cancelExist==false)' | jq -sr '.[0].createdAt') / 1000 | bc)"	# already in epoch milliseconds on kucoin, so divide by 1000 before we covert to date
		trade_history_timestamp="$(date -d @"$trade_history_timestamp_kucoin")"

		# Align trade types with bot & cryptopia
		if [ "$trade_history_type_kucoin" = "sell" ]; then
			trade_history_type="Sell"
		elif [ "$trade_history_type_kucoin" = "buy" ]; then
			trade_history_type="Buy"
		else
			echo "Error: unknown trade history type: $trade_history_type_kucoin"
			return 1
		fi
		### Need to add a check if to determine if it's the first trade and ignore zero values. Really it should be null value... need to investigate
		#api_value_validator "number" "$trade_history_id" "get_trade_history id" || return 1
		#api_value_validator "string" "$trade_history_type" "get_trade_history type" || return 1
		api_value_validator "number" "$trade_history_cost" "get_trade_history cost" || return 1
		api_value_validator "number" "$trade_history_rate" "get_trade_history rate" || return 1
		api_value_validator "number" "$trade_history_amount" "get_trade_history amount" || return 1
	fi
}
