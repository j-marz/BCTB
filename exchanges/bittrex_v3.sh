#!/bin/bash

# Bittrex Exchange - variables & functions
# ----------------------------------------
# API documentation:  https://bittrex.github.io/api/v3 

# API rate limiting: 60 api calls per minute

# Variables
#market_name="$quote_currency-$base_currency"	# must be upper case in config - should validate this!
market_name="$base_currency-$quote_currency"	# reversed in v3 API
sell_amount_requires_fee="false"	# set to false if exchange handles fee math on sell orders

# Functions
private_api_query() {
	endpoint="$1"
	http_method="$2"
	body="$3"
	[ -z "$3" ] && body=""	# content hash needs empty string for requests with no body
	url="https://api.bittrex.com/v3/$endpoint"
	private_timestamp="$(date +%s%3N)"
	content_hash="$(echo -n "$body" | sha512sum | tr -d " -")"
	pre_sign="$private_timestamp$url$http_method$content_hash"
	hmacsignature="$(echo -n "$pre_sign" | openssl dgst -sha512 -hmac "$api_secret" | sed 's/^.*= //')"
	
	if [ "$http_method" = "POST" ]; then
		#request="--request $http_method --data-raw $body"	# passing empty body causes issues with http status code, so only include if POST method
			# passing body in request variable was causing issues with content hash, so split POST and other request methods
		curl \
		--silent \
		--write-out "\n%{http_code}\n" \
		--header "Content-Type: application/json" \
		--header "Api-Key: $api_key" \
		--header "Api-Timestamp: $private_timestamp" \
		--header "Api-Content-Hash: $content_hash" \
		--header "Api-Signature: $hmacsignature" \
		--url "$url" \
		--request "$http_method" \
		--data-raw "$body"
	else
		curl \
		--silent \
		--write-out "\n%{http_code}\n" \
		--header "Content-Type: application/json" \
		--header "Api-Key: $api_key" \
		--header "Api-Timestamp: $private_timestamp" \
		--header "Api-Content-Hash: $content_hash" \
		--header "Api-Signature: $hmacsignature" \
		--url "$url" \
		--request "$http_method"
	fi
}

public_api_query() {
	endpoint="$1"
	url="https://api.bittrex.com/v3/$endpoint"

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
		rsp_error_detail="$(grep '{' "$response" | jq -r .detail)"
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
}

# Public API calls

# /public/getticker & /public/getmarketsummary
	#https://bittrex.github.io/guides/v3/upgrade
get_market() {
	market="$(mktemp "$tmp_file_template")"
	public_api_query "markets/$market_name/ticker" > "$market"	#https://bittrex.github.io/api/v3#operation--markets--marketSymbol--ticker-get
	api_response_parser "$market" "get_market" || return 1
	market_ask="$(grep '{' "$market" | jq -r '.askRate' | xargs printf "%.8f")"
	market_bid="$(grep '{' "$market" | jq -r '.bidRate' | xargs printf "%.8f")"
	market_last_price="$(grep '{' "$market" | jq -r '.lastTradeRate' | xargs printf "%.8f")"

	api_value_validator "number" "$market_ask" "get_market ask" || return 1
	api_value_validator "number" "$market_bid" "get_market bid" || return 1

	market_summary="$(mktemp "$tmp_file_template")"
	public_api_query "markets/$market_name/summary" > "$market_summary"	#https://bittrex.github.io/api/v3#operation--markets--marketSymbol--summary-get
	api_response_parser "$market_summary" "get_market_summary" || return 1
	market_volume="$(grep '{' "$market_summary" | jq -r '.volume' | xargs printf "%.8f")"	# base (alt coin) volume
	market_base_volume="$(grep '{' "$market_summary" | jq -r '.quoteVolume' | xargs printf "%.8f")"	# quote (BTC) volume
	#market_open_buy_orders="$(grep '{' "$market_summary" | jq -r '.result[].OpenBuyOrders' | xargs printf "%.8f")"
	#market_open_buy_orders="$(grep '{' "$market_summary" | jq -r '.result[].OpenSellOrders' | xargs printf "%.8f")"
}

# GetMarkets
# https://bittrex.github.io/api/v3#operation--markets-summaries-get
get_markets() {
	# used to decide on market to trade based on market base volumes
	markets="$(mktemp "$tmp_file_template")"
	markets_filtered="$(mktemp "$tmp_file_template")"
	markets_blacklist_cmd="$(mktemp "$tmp_file_template")"
	public_api_query "markets/summaries" > "$markets"
	api_response_parser "$markets" "get_markets" || return 1

	# filter out blacklisted and non-BTC markets
	blacklist_manager "list" || return 1
	if [ "$blacklist_empty" = "true" ]; then
		grep '{' "$markets" | jq -r --arg quote_currency "-$quote_currency" '.[] | select(.symbol | contains($quote_currency))' > "$markets_filtered"
	else
		# hack to workaround jq not accepting commands stored in variables
		echo "grep '{' $markets | jq -r '.[] | select(.symbol | contains(\"-$quote_currency\")) | select(.symbol | $blacklist_contains | not)'" > "$markets_blacklist_cmd"
		bash "$markets_blacklist_cmd" > "$markets_filtered"
	fi

	previous_market_name="$market_name"
	market_volume="$(jq -s -r 'sort_by(.quoteVolume) | .[-1] | .volume' "$markets_filtered" | xargs printf "%.8f")"	# base (alt coin) volume
	market_base_volume="$(jq -s -r 'sort_by(.quoteVolume) | .[-1] | .quoteVolume' "$markets_filtered" | xargs printf "%.8f")"	# quote (BTC) volume
	#market_buy_base_volume="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .BuyBaseVolume' "$markets_filtered" | xargs printf "%.8f")"
	#market_sell_base_volume="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .SellBaseVolume' "$markets_filtered" | xargs printf "%.8f")"
	market_name="$(jq -s -r 'sort_by(.quoteVolume) | .[-1] | .symbol' "$markets_filtered")"	# select market with largest base volume
	base_currency="$(echo "$market_name" | awk -F '-' '{print $1}')"	# reversed in v3
}

# /public/getmarkets
get_trade_pairs() {
	trade_pairs="$(mktemp "$tmp_file_template")"
	public_api_query markets > "$trade_pairs"	#https://bittrex.github.io/api/v3#operation--markets-get
	api_response_parser "$trade_pairs" "get_trade_pairs" || return 1
	market_fees="$(mktemp "$tmp_file_template")"
	private_api_query "account/fees/trading/$market_name" GET > "$market_fees"
	api_response_parser "$market_fees" "get_market_fees" || return 1
	market_makerRate="$(grep '{' "$market_fees" | jq -r '.makerRate' | tr -d '"')"
	trade_fee="$(echo "$market_makerRate * 100" | bc -l | xargs printf "%.2f")"
	min_trade_size="$(grep '{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.[] | select(.symbol==$market_name) | .minTradeSize')"
	get_market
	min_base_trade="$(echo "$min_trade_size * $market_last_price" | bc -l | xargs printf "%.8f")"
	trade_pair_status="$(grep '{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.[] | select(.symbol==$market_name) | .status')"
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
	if [ "$trade_pair_status" != "ONLINE" ]; then
		echo "WARN: $market_name status is $trade_pair_status"
		echo "Adding $market_name to blacklist"
		blacklist_manager "add" "$market_name" "1" "bad market status" || return 1
		return 1
	fi
}

# GetMarketOrders - needs to be ported to Bittrex API
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

# /public/getmarkethistory
get_market_history() {
	# add all prices from a given time period and divide by the number of prices to work out the average
	market_history_hours="24"	# currently not used by bittrex - time period not accepted - last 100 results returned everytime
	market_history="$(mktemp "$tmp_file_template")"
	public_api_query "markets/$market_name/trades" > "$market_history"	#https://bittrex.github.io/api/v3#operation--markets--marketSymbol--trades-get
	api_response_parser "$market_history" "get_market_history" || return 1
	market_history_prices="$(grep '{' "$market_history" | jq -r '.[].rate')"
	market_history_trade_count="$(echo "$market_history_prices" | wc -l)"
	if [ "$market_history_trade_count" -lt "$sma_period" ]; then
		echo "Error: Trade count ($market_history_trade_count) is less than expected SMA period ($sma_period)"
		send_email "Error: Trade count not met!" "Trade count: $market_history_trade_count \nSMA period config: $sma_period" "$market_history"
		return 1	# avoid incorrect averages when market count not met
	fi
}

get_candles() {
#  GET /markets/{marketSymbol}/candles/{candleType}/{candleInterval}/recent 
# https://bittrex.github.io/api/v3#tag-Markets

	candles="$(mktemp "$tmp_file_template")"
	# candleInterval: string MINUTE_1, MINUTE_5, HOUR_1, DAY_1 
	# convert candles_interval minutes to bittrex tickInterval param (rounds up)
	if [ "$candles_interval" -le 1 ]; then
		dataGroup="MINUTE_1"		# 1 minute
	elif [ "$candles_interval" -le 5 ]; then
		dataGroup="MINUTE_5"		# 5 minutes
	elif [ "$candles_interval" -le 60 ]; then
		dataGroup="HOUR_1"		# 1 hour
	elif [ "$candles_interval" -le 1440 ]; then
		dataGroup="DAY_1"			# 1 day
	else
		echo "Error: Unknown candles interval ($candles_interval) for current exchange"
		send_email "Error: Get candles interval!" "Unknown candles interval ($candles_interval) for current exchange" "$candles"
		return 1
	fi

	candleType="trade" # trade | midpoint

	public_api_query "/markets/$market_name/candles/$candleType/$dataGroup/recent" > "$candles"
	api_response_parser "$candles" "get_candles" || return 1

	candles_open_list="$(grep '{' "$candles" | jq -r '.[].open')"
	candles_high_list="$(grep '{' "$candles" | jq -r '.[].high')"
	candles_low_list="$(grep '{' "$candles" | jq -r '.[].low')"
	candles_close_list="$(grep '{' "$candles" | jq -r '.[].close')"

	#How to filter candles - head when newest first, tail when newest last
	candles_filter="tail"
}


# Private API calls

# /account/getbalance
# https://bittrex.github.io/api/v3#operation--balances--currencySymbol--get
# https://bittrex.github.io/api/v3#operation--balances-get
get_balance() {
	currency="$1"
	#balance_currency="currency=$currency"
	balance="$(mktemp "$tmp_file_template")"
	if [ -z "$currency" ]; then
		private_api_query balances GET > "$balance"
	else
		private_api_query "balances/$currency" GET > "$balance"
	fi
### api value validator should probably be used here, but how to determine if the balance is truely zero?
	api_response_parser "$balance" "get_balance" || return 1
	bittrex_balance="$(grep '{' "$balance" | jq -r '.available')"
	# handle empty balances in bittrex exchange
	if [ "$bittrex_balance" = "" ]; then
		available_balance="0"
	elif [ "$bittrex_balance" = "null" ]; then
		available_balance="0"
	else
		available_balance="$(echo "$bittrex_balance" | xargs printf "%.8f")"
	fi
}

# /market/getopenorders
# https://bittrex.github.io/api/v3#operation--orders-open-get
get_open_orders() {
	tradepair="marketSymbol=$market_name"
	open_orders="$(mktemp "$tmp_file_template")"
	private_api_query "orders/open?$tradepair" GET > "$open_orders"
	api_response_parser "$open_orders" "get_open_orders" || return 1
	##### need to handle multiple open orders?
	open_order_check="$(grep '{' "$open_orders" | jq -r '.[]')"
	if [ -z "$open_order_check" ]; then
		no_open_orders="true"
		echo "No open order(s) for $market_name market"
	else
		no_open_orders="false"
		echo "Open order(s) found for $market_name market"
		open_order_id="$(grep '{' "$open_orders" | jq -r '.[].id')"
		open_order_amount="$(grep '{' "$open_orders" | jq -r '.[].quantity')"
		open_order_amount_remaining="$(grep '{' "$open_orders" | jq -r '.[].fillQuantity')"
		open_order_amount_filled="$(echo "$last_trade_amount - $open_order_amount_remaining" | bc -l | xargs printf "%.8f")"
	fi
}

# /market/buylimit & /market/selllimit
# https://bittrex.github.io/api/v3#operation--orders-post
# https://bittrex.github.io/api/v3#operation--orders-post
# Order types: https://bittrex.com/discover/understanding-bittrex-order-types
	# GOOD_TIL_CANCELLED || IMMEDIATE_OR_CANCEL || FILL_OR_KILL
submit_trade_order() {
	submit_trade="$(mktemp "$tmp_file_template")"
	if [ "$trade_type" = "Buy" ]; then
		trade='{"marketSymbol": "'"$market_name"'","type": "LIMIT","quantity": "'"$trade_amount"'","limit": "'"$trade_rate"'","timeInForce": "GOOD_TIL_CANCELLED","direction": "BUY"}'
		private_api_query orders POST "$trade" > "$submit_trade"
	elif [ "$trade_type" = "Sell" ]; then
		#if [ "$ma_sell" = "maximum" ]; then
			# use market order to sell entire balance at market rate - this may incur slipage!!!
		#	trade='{"marketSymbol": "'"$market_name"'","type": "MARKET","timeInForce": "GOOD_TIL_CANCELLED","direction": "SELL"}'
		#	private_api_query orders POST "$trade" > "$submit_trade"
		#else
			# use limit order
			trade='{"marketSymbol": "'"$market_name"'","type": "LIMIT","quantity": "'"$trade_amount"'","limit": "'"$trade_rate"'","timeInForce": "GOOD_TIL_CANCELLED","direction": "SELL"}'
			private_api_query orders POST "$trade" > "$submit_trade"
		#fi
	fi
	api_response_parser "$submit_trade" "submit_trade_order" || return 1
	last_order_id="$(grep '{' "$submit_trade" | jq -r '.id')"
	last_trade_type="$trade_type"	
	last_trade_cost="$trade_total_cost"
	#last_trade_rate="$trade_rate"	# not used 
	last_trade_amount="$trade_amount"
	filled_orders="$(grep '{' "$submit_trade" | jq -r '.fillQuantity')"
	#filled_orders_count="0"	##### not available from this bittrex api call
	echo "$trade_type trade submitted!"
	echo "Trade Id: $last_order_id"
	echo "Trade amount: $last_trade_amount"
	echo "Trade cost: $last_trade_cost"
	echo "Filled orders: $filled_orders"
	if [ "$filled_orders" -gt 0 ]; then 	### THIS ISN'T WORKING AS IT'S A FLOAT INSTEAD OF INTEGER
		echo "Trade filled :)"
	else
		echo "Trade open..."
	fi
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

# /market/cancel
# https://bittrex.github.io/api/v3#operation--orders--orderId--delete
cancel_trade_order() {
	order_id="$1"
	#trade="uuid=$order_id"
	cancel_trade="$(mktemp "$tmp_file_template")"
	private_api_query "orders/$order_id" DELETE > "$cancel_trade"
	api_response_parser "$cancel_trade" "cancel_trade_order" || return 1
	cancel_trade_data="$(grep '{' "$cancel_trade" | jq -r '.')"
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

# /account/getorderhistory
# https://bittrex.github.io/api/v3#operation--orders-closed-get
get_trade_history() {
	count="$1"
	#past_trades="market=$market_name"
	trade_history="$(mktemp "$tmp_file_template")"
	private_api_query "orders/closed?marketSymbol=$market_name&pageSize=$count" GET > "$trade_history"
	api_response_parser "$trade_history" "get_trade_history" || return 1
	emtpy_history="$(grep '{' "$trade_history" | jq -r '.[]')"
	if [ "$emtpy_history" = "" ]; then
		no_history="true"
		echo "no trade history found"
	else
		trade_history_id="$(grep '{' "$trade_history" | jq -r '.[].id')"
		trade_history_market="$(grep '{' "$trade_history" | jq -r '.[].marketSymbol')"
		trade_history_base_currency="$(echo "$trade_history_market" | awk -F '-' '{print $1}')"
		trade_history_type_bittrex="$(grep '{' "$trade_history" | jq -r '.[].direction')"
		trade_history_cost="$(grep '{' "$trade_history" | jq -r '.[].proceeds' | xargs printf "%.8f")"
		trade_history_rate="$(grep '{' "$trade_history" | jq -r '.[].limit' | xargs printf "%.8f")"
		trade_history_quantity="$(grep '{' "$trade_history" | jq -r '.[].quantity' | xargs printf "%.8f")"
		trade_history_amount="$(grep '{' "$trade_history" | jq -r '.[].fillQuantity' | jq -r -s 'add' | xargs printf "%.8f")" # sum for split filled orders
		trade_history_timestamp="$(grep '{' "$trade_history" | jq -r '.[].createdAt')"

		###### probably need to handle cancelled orders that have 0 trade amount after minusing quantity remaining....?

		# Align trade types with bot & cryptopia
		if [ "$trade_history_type_bittrex" = "SELL" ]; then
			trade_history_type="Sell"
		elif [ "$trade_history_type_bittrex" = "BUY" ]; then
			trade_history_type="Buy"
		else
			echo "Error: unknown trade history type: $trade_history_type"
			return 1
		fi
		### Need to add a check if to determine if it's the first trade and ignore zero values. Really it should be null value... need to investigate
		#api_value_validator "number" "$trade_history_id" "get_trade_history id" || return 1	### ID is a GUID in Bittrex & error checking handled above in trade type alignment
		#api_value_validator "string" "$trade_history_type" "get_trade_history type" || return 1
		api_value_validator "number" "$trade_history_cost" "get_trade_history cost" || return 1
		api_value_validator "number" "$trade_history_rate" "get_trade_history rate" || return 1
		api_value_validator "number" "$trade_history_amount" "get_trade_history amount" || return 1
	fi
}
