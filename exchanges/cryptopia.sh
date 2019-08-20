#!/bin/bash

# Cryptopia Exchange - variables & functions
# ------------------------------------------
# Public API doco: https://www.cryptopia.co.nz/Forum/Thread/255 OR https://support.cryptopia.co.nz/csm?id=kb_article&sys_id=40e9c310dbf9130084ed147a3a9619eb
# Private API doco: https://www.cryptopia.co.nz/Forum/Thread/256 OR https://support.cryptopia.co.nz/csm?id=kb_article&sys_id=a75703dcdbb9130084ed147a3a9619bc

# API rate limiting:
#	1,000 req/min
#	1,000,000 req/day

# Variables

market_name="$base_currency/$quote_currency"	# cryptopia requires base/quote (e.g. ETN/BTC)

# Functions

private_api_query() {
	method="$1"	
	post_data="$2"
	[ -z "$post_data" ] && post_data="{}"
	url="https://www.cryptopia.co.nz/Api/$method"
	nonce="$(date +%s%N)" # added nano seconds to avoid nonce reuse within same second
	requestContentBase64String="$( printf "%s" "$post_data" | openssl dgst -md5 -binary | base64 )"
	url_encoded="$( printf "%s" "$url" | curl -Gso /dev/null -w %{url_effective} --data-urlencode @- "" | cut -c 3- | awk '{print tolower($0)}')"
	signature="${api_key}POST${url_encoded}${nonce}${requestContentBase64String}"
	hmacsignature="$(echo -n "$signature" | openssl sha256 -binary -hmac "$(echo -n "$api_secret" | base64 -d)" | base64 )"
	header_value="amx ${api_key}:${hmacsignature}:${nonce}"
	
	curl \
	--silent \
	--write-out "\n%{http_code}\n" \
	--header "Authorization: $header_value" \
	--header "Content-Type: application/json; charset=utf-8" \
	--request "POST" \
	--data "${post_data}" \
	"${url}"
}

public_api_query() {
	method="$1"
	get_param1="$2"
	get_param2="/$3"
	[ -z "$get_param1" ] && get_param1=""
	[ -z "$get_param2" ] && get_param2=""	# should probably change to [ -z "$3" ] as slash will always be present.. or move slash to url..
	#url="https://www.cryptopia.co.nz/api/$method/$get_param1"
	url="https://www.cryptopia.co.nz/api/$method/$get_param1$get_param2"

	curl \
	--silent \
	--write-out "\n%{http_code}\n" \
	--header "Content-Type: application/json" \
	--request "GET" \
	"$url"
}

### This might be better in bot_functions.sh if other exchanges use the same sort of responses
api_response_parser() {
	response="$1"
	calling_function="$2"
	rsp_success="$(grep '^{' "$response" | jq -r .Success)"
	rsp_error="$(grep '^{' "$response" | jq -r .Error)"
	declare -i http_status	# only allow integer for http status code
	http_status="$(tail -n 1 "$response")" # last line contains http_code from cURL
	if [ "$rsp_success" = "true" ]; then
		echo "$calling_function api call successful - http status code: $http_status"
		failed_error_count="1"	# reset counter
		unexpected_error_count="1"	# reset counter
	elif [ "$rsp_success" = "false" ]; then
		echo "$calling_function api call failed"
		echo "api rsp: $rsp_success"
		echo "api error: $rsp_error"
		echo "http status code: $http_status"
		send_email "ERROR: $calling_function api call failed" "api rsp: $rsp_success \napi error: $rsp_error \nhttp status code: $http_status" "$response"
		let failed_error_count=failed_error_count+1
		failed_error_sleep_time="$(echo "20 * $failed_error_count" | bc -l)" # increase sleep time on consecutive errors
		sleep "$failed_error_sleep_time"	# sleep in case of API issues
		return 1	# restart main trading loop
	else
		echo "$calling_function api call unexpected response"
		echo "api rsp: $rsp_success"
		echo "api error: $rsp_error"
		echo "http status code: $http_status"
		echo "posssible network issues or API outage"
		send_email "ERROR: $calling_function api call unexpected response" "api rsp: $rsp_success \napi error: $rsp_error \nhttp status code: $http_status" "$response"
		let unexpected_error_count=unexpected_error_count+1
		unexpected_error_sleep_time="$(echo "60 * $unexpected_error_count" | bc -l)" # increase sleep time on consecutive errors
		sleep "$unexpected_error_sleep_time"	# sleep in case of API issues
		return 1	# restart main trading loop
	fi
}

# Public API calls
# GetTradePairs
get_trade_pairs() {
	trade_pairs="$(mktemp "$tmp_file_template")"
	public_api_query GetTradePairs > "$trade_pairs"
	api_response_parser "$trade_pairs" "get_trade_pairs" || return 1
	trade_fee="$(grep '^{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.Data[] | select(.Label==$market_name) | .TradeFee')"
	min_base_trade="$(grep '^{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.Data[] | select(.Label==$market_name) | .MinimumBaseTrade')"
	trade_pair_id="$(grep '^{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.Data[] | select(.Label==$market_name) | .Id')"
	trade_pair_status="$(grep '^{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.Data[] | select(.Label==$market_name) | .Status')"
	# check if trade fee has changed from expected amount
	compare_trade_fee="$(echo "$trade_fee == $expected_trade_fee" | bc -l)"
	if [ "$compare_trade_fee" -ne 1 ]; then
		echo "WARN: Trade fee has changed!"
		echo "Expected fee: $expected_trade_fee"
		echo "Current fee: $trade_fee"
		send_email "WARN: Trade fee has changed!" "Expected fee: $expected_trade_fee \nCurrent fee: $trade_fee"
	fi
	# check trade pair status
	if [ "$trade_pair_status" != "OK" ]; then
		if [ "$trade_pair_status" = "" ]; then 	# workaround cryptopia api issues
			echo "ERROR: Cryptopia returned an empty value for trade pair status"
			return 1
		fi
		echo "WARN: $market_name status is $trade_pair_status"
		echo "Adding $market_name to blacklist"
		blacklist_manager "add" "$market_name" "1" "bad market status" || return 1
		return 1
	fi
}

# GetMarket
get_market() {
	market_hours="$1"
	market="$(mktemp "$tmp_file_template")"
	market_name_get="$(echo "$market_name" | tr "/" "_")"
	public_api_query GetMarket "$market_name_get" "$market_hours" > "$market"
	api_response_parser "$market" "get_market" || return 1
	market_ask="$(grep '^{' "$market" | jq -r '.Data.AskPrice' | xargs printf "%.8f")"
	market_bid="$(grep '^{' "$market" | jq -r '.Data.BidPrice' | xargs printf "%.8f")"
	market_last_price="$(grep '^{' "$market" | jq -r '.Data.LastPrice' | xargs printf "%.8f")"
	market_volume="$(grep '^{' "$market" | jq -r '.Data.Volume' | xargs printf "%.8f")"	# base (alt coin) volume
	market_base_volume="$(grep '^{' "$market" | jq -r '.Data.BaseVolume' | xargs printf "%.8f")"	# quote (BTC) volume
	#market_open_buy_orders="$(grep '^{' "$market" | jq -r '.Data.OpenBuyOrders' | xargs printf "%.8f")"
	#market_open_buy_orders="$(grep '^{' "$market" | jq -r '.Data.OpenSellOrders' | xargs printf "%.8f")"
	api_value_validator "number" "$market_ask" "get_market ask" || return 1
	api_value_validator "number" "$market_bid" "get_market bid" || return 1
}

# GetMarkets
get_markets() {
	# used to decide on market to trade based on market base volumes
	markets="$(mktemp "$tmp_file_template")"
	markets_filtered="$(mktemp "$tmp_file_template")"
	markets_blacklist_cmd="$(mktemp "$tmp_file_template")"
	public_api_query GetMarkets "$quote_currency" > "$markets"
	api_response_parser "$markets" "get_markets" || return 1

	# filter out blacklisted markets
	blacklist_manager "list" || return 1
	if [ "$blacklist_empty" = "true" ]; then
		grep '^{' "$markets" | jq -r '.Data[]' > "$markets_filtered"
	else
		# hack to workaround jq not accepting commands stored in variables
		echo "grep '^{' $markets | jq -r '.Data[] | select(.Label | $blacklist_contains | not)'" > "$markets_blacklist_cmd"
		bash "$markets_blacklist_cmd" > "$markets_filtered"
	fi

	previous_market_name="$market_name"
	market_volume="$(jq -r -s 'sort_by(.BaseVolume) | .[-1] | .Volume' "$markets_filtered" | xargs printf "%.8f")"	# base (alt coin) volume
	market_base_volume="$(jq -r -s 'sort_by(.BaseVolume) | .[-1] | .BaseVolume' "$markets_filtered" | xargs printf "%.8f")"	# quote (BTC) volume
	#market_buy_base_volume="$(jq -r -s '.Data | sort_by(.BaseVolume) | .[-1] | .BuyBaseVolume' "$markets_filtered" | xargs printf "%.8f")"
	#market_sell_base_volume="$(jq -r -s '.Data | sort_by(.BaseVolume) | .[-1] | .SellBaseVolume' "$markets_filtered" | xargs printf "%.8f")"
	market_name="$(jq -r -s 'sort_by(.BaseVolume) | .[-1] | .Label' "$markets_filtered")"	# select market with largest base volume
	base_currency="$(echo "$market_name" | awk -F '/' '{print $1}')"
}

# GetMarketOrders
#get_market_orders() {
	#market_orders_limit="10"	# number of open buy and sell market orders to retrieve
	#market_orders="$(mktemp "$tmp_file_template")"
	#market_name_get="$(echo "$market_name" | tr / _)"
	#public_api_query GetMarketOrders "$market_name_get" "$market_orders_limit" > "$market_orders"
	#api_response_parser "$market_orders" "get_market_orders" || return 1
	#market_orders_buy="$(grep '^{' "$market_orders" | jq -r '.Data.Buy[].Price')"
	#market_orders_sell="$(grep '^{' "$market_orders" | jq -r '.Data.Sell[].Price')"
	#market_buy_average="$(echo "$market_orders_buy" | jq -r -s 'add/length' | xargs printf "%.8f")"
	#market_sell_average="$(echo "$market_orders_sell" | jq -r -s 'add/length' | xargs printf "%.8f")"
#}

# GetMarketHistory
get_market_history() {
	# add all prices from a given time period and divide by the number of prices to work out the average
	market_history_hours="24"	# cryptopia default hours (24) - safe option for slow trading days
	market_history="$(mktemp "$tmp_file_template")"
	market_name_get="$(echo "$market_name" | tr "/" "_")"
	public_api_query GetMarketHistory "$market_name_get" "$market_history_hours" > "$market_history"
	api_response_parser "$market_history" "get_market_history" || return 1
	market_history_prices="$(grep '^{' "$market_history" | jq -r '.Data[].Price')"
	market_history_trade_count="$(echo "$market_history_prices" | wc -l)"
	if [ "$market_history_trade_count" -lt "$sma_period" ]; then
		echo "Error: Trade count ($market_history_trade_count) is less than expected SMA period ($sma_period)"
		send_email "Error: Trade count not met!" "Trade count: $market_history_trade_count \nSMA period config: $sma_period" "$market_history"
		return 1	# avoid incorrect averages when market count not met
	fi
}

# Private API calls

# GetBalance	
get_balance() {
	currency="$1"
	balance_currency='{"Currency": "'$currency'"}'
	[ -z "$currency" ] && balance_currency=""	# to retrieve all balances
	balance="$(mktemp "$tmp_file_template")"
	private_api_query GetBalance "$balance_currency" > "$balance"
### api value validator should probably be used here, but how to determine if the balance is truely zero?
	rsp_error="$(grep '^{' "$balance" | jq -r .Error)"
	if [ "$rsp_error" = "No balance found" ]; then 	# must be before api_response_parser because success will be false (sometimes)...
		echo "No balance found for $currency - setting available balance to zero"
		available_balance="0"
	else
		api_response_parser "$balance" "get_balance" || return 1
		#total_balance="$(grep '^{' "$balance" | jq -r '.Data[].Total' | xargs printf "%.8f")"	# not used
		available_balance="$(grep '^{' "$balance" | jq -r '.Data[].Available' | xargs printf "%.8f")"
		#held_balance="$(grep '^{' "$balance" | jq -r '.Data[].HeldForTrades' | xargs printf "%.8f")"	# not used
		#useable_balance="$(echo "$available_balance - $minimum_coin_balance" | bc -l | xargs printf "%.8f")"	# use if minimum amount of coins should be kept	
	fi
}

# GetOpenOrders
get_open_orders() {
	tradepair='{"Market": "'$market_name'"}'
	open_orders="$(mktemp "$tmp_file_template")"
	private_api_query GetOpenOrders "$tradepair" > "$open_orders"
	api_response_parser "$open_orders" "get_open_orders" || return 1
	##### need to handle multiple open orders?
	open_order_check="$(grep '^{' "$open_orders" | jq -r --arg market_name "$market_name" '.Data[]')"
	if [ -z "$open_order_check" ]; then
		no_open_orders="true"
		echo "No open order(s) for $market_name market"
	else
		no_open_orders="false"
		echo "Open order(s) found for $market_name market"
		open_order_id="$(grep '^{' "$open_orders" | jq -r --arg market_name "$market_name" '.Data[] | select(.Market==$market_name) | .OrderId')"
		open_order_amount="$(grep '^{' "$open_orders" | jq -r --argjson order_id "$open_order_id" '.Data[] | select(.OrderId==$order_id) | .Amount' | xargs printf "%.8f")"
		open_order_amount_remaining="$(grep '^{' "$open_orders" | jq -r --argjson order_id "$open_order_id" '.Data[] | select(.OrderId==$order_id) | .Remaining' | xargs printf "%.8f")"
		open_order_amount_filled="$(echo "$last_trade_amount - $open_order_amount_remaining" | bc -l | xargs printf "%.8f")"
		#open_order_total="$(grep '^{' "$open_orders" | jq -r --argjson order_id "$open_order_id" '.Data[] | select(.OrderId==$order_id) | .Total' | xargs printf "%.8f")"	# not used
		#open_order_type="$(grep '^{' "$open_orders" | jq -r --argjson order_id "$open_order_id" '.Data[] | select(.OrderId==$order_id) | .Type')"	# not used
		#open_order_rate="$(grep '^{' "$open_orders" | jq -r --argjson order_id "$open_order_id" '.Data[] | select(.OrderId==$order_id) | .Rate' | xargs printf "%.8f")"	# not used
	fi
}

# SubmitTrade
submit_trade_order() {
	trade='{"Market": "'$market_name'", "Type": "'$trade_type'", "Rate": "'$trade_rate'", "Amount": "'$trade_amount'"}'
	submit_trade="$(mktemp "$tmp_file_template")"
	private_api_query SubmitTrade "$trade" > "$submit_trade"
	api_response_parser "$submit_trade" "submit_trade_order" || return 1
	last_order_id="$(grep '^{' "$submit_trade" | jq -r '.Data.OrderId')"
	last_trade_type="$trade_type"	
	last_trade_cost="$trade_total_cost"
	#last_trade_rate="$trade_rate"	# not used 
	last_trade_amount="$trade_amount"
	filled_orders="$(grep '^{' "$submit_trade" | jq -r '.Data.FilledOrders[]')"
	filled_orders_count="$(grep '^{' "$submit_trade" | jq '.Data.FilledOrders | length')"	# no -r in jq otherwise use "jq -r '.Data.FilledOrders[]' "$submit_trade" | wc -l"
	echo "$trade_type trade submitted!"
	echo "Trade Id: $last_order_id"
	echo "Trade amount: $last_trade_amount"
	echo "Trade cost: $last_trade_cost"
	echo "Filled orders: $filled_orders"
	if [ "$filled_orders_count" -ge 1 ]; then
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

# CancelTrade
cancel_trade_order() {
	order_id="$1"
	trade='{"Type": "Trade", "OrderId": "'$order_id'"}'
	cancel_trade="$(mktemp "$tmp_file_template")"
	private_api_query CancelTrade "$trade" > "$cancel_trade"
	api_response_parser "$cancel_trade" "cancel_trade_order" || return 1
	cancel_trade_data="$(grep '^{' "$cancel_trade" | jq -r '.Data[]')"
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

# GetTradeHistory
get_trade_history() {
	count="$1"
	past_trades='{"Market": "'$market_name'", "Count": "'$count'"}'
	trade_history="$(mktemp "$tmp_file_template")"
	private_api_query GetTradeHistory "$past_trades" > "$trade_history"
	api_response_parser "$trade_history" "get_trade_history" || return 1
	emtpy_history="$(grep '^{' "$trade_history" | jq -r '.Data[]')"
	if [ "$emtpy_history" = "" ]; then
		no_history="true"
		echo "no trade history found"
	else
		if [ "$filled_orders_count" -gt 1 ]; then # this still doesn't cover orders that aren't fully filled...
			trade_history_id="$(grep '^{' "$trade_history" | jq -r '.Data[].TradeId')"
			trade_history_market="$(grep '^{' "$trade_history" | jq -r '.Data[].Market' | sort -u)"
			trade_history_base_currency="$(echo "$trade_history_market" | awk -F '/' '{print $1}')"
			trade_history_type="$(grep '^{' "$trade_history" | jq -r '.Data[].Type' | sort -u)" # dedup type - should be the same for multi-filled orders anyway
			trade_history_cost="$(grep '^{' "$trade_history" | jq -r '.Data[].Total' | jq -r -s 'add' | xargs printf "%.8f")" # sum for split filled orders
			trade_history_rate="$(grep '^{' "$trade_history" | jq -r '.Data[].Rate' | jq -r -s 'add/length' | xargs printf "%.8f")" # average for split orders
			trade_history_amount="$(grep '^{' "$trade_history" | jq -r '.Data[].Amount' | jq -r -s 'add' | xargs printf "%.8f")" # sum for split filled orders
			trade_history_timestamp="$(grep '^{' "$trade_history" | jq -r '.Data[0].TimeStamp')"	# only take latest timestamp
			trade_history_timestamp_all="$(grep '^{' "$trade_history" | jq -r '.Data[].TimeStamp')"	# all timestamps in multi-filled order scenario
		else
			trade_history_id="$(grep '^{' "$trade_history" | jq -r '.Data[].TradeId')"
			trade_history_market="$(grep '^{' "$trade_history" | jq -r '.Data[].Market')"
			trade_history_base_currency="$(echo "$trade_history_market" | awk -F '/' '{print $1}')"
			trade_history_type="$(grep '^{' "$trade_history" | jq -r '.Data[].Type')"
			trade_history_cost="$(grep '^{' "$trade_history" | jq -r '.Data[].Total' | xargs printf "%.8f")"
			trade_history_rate="$(grep '^{' "$trade_history" | jq -r '.Data[].Rate' | xargs printf "%.8f")"
			trade_history_amount="$(grep '^{' "$trade_history" | jq -r '.Data[].Amount' | xargs printf "%.8f")"
			trade_history_timestamp="$(grep '^{' "$trade_history" | jq -r '.Data[].TimeStamp')"
		fi
		### Need to add a check if to determine if it's the first trade and ignore zero values. Really it should be null value... need to investigate
		api_value_validator "number" "$trade_history_id" "get_trade_history id" || return 1
		#api_value_validator "string" "$trade_history_type" "get_trade_history type" || return 1
		#api_value_validator "number" "$trade_history_cost" "get_trade_history cost" || return 1 # disabling due to cryptopia sometimes allowing 0 cost trades...
		api_value_validator "number" "$trade_history_rate" "get_trade_history rate" || return 1
		api_value_validator "number" "$trade_history_amount" "get_trade_history amount" || return 1
	fi
}


## Unofficial web calls - not part of public or private APIs ##

# Get candles for long term moving average calcs
get_candles() {
	#https://www.cryptopia.co.nz/Exchange/GetTradePairChart?tradePairId=5662&dataRange=0&dataGroup=60
	# dataGroup (mins) - 15,30,60,120(2h),240(4h),720(12h),1440(1d),10080(1w) - # can be any number (ie. 1min)
	# dataRange (sequential) - 0(1d), 1(2d), 2(1w), 3(2w), 4(1M), 5(3M), 6(6M), 7(all time)
	# OHLVC:
		# Open, High, Low, Close
		# Volume separate

# _ timestamp param doesn't appear to be required for requests. The same data is returned without the param.

# timestamp needs last 3 numbers trimmed so gnu date can process
# 1540156783398 --> 1540156783

# dataRange param is required, but API returns greater range regardless...

	candles="$(mktemp "$tmp_file_template")"
	candles_range="$(echo "$candles_interval * $sma_period" | bc -l)"
	# calculate dataRange param value based on sma period
	if [ "$candles_range" -le 1440 ]; then
		dataRange="0"	# 1 day
	elif [ "$candles_range" -le 2880 ]; then
		dataRange="1"	# 2 days
	elif [ "$candles_range" -le 10080 ]; then
		dataRange="2"	# 1 week
	elif [ "$candles_range" -le 20160 ]; then
		dataRange="3"	# 2 weeks
	elif [ "$candles_range" -le 43800 ]; then
		dataRange="4"	# 1 month
	elif [ "$candles_range" -le 131400 ]; then
		dataRange="5"	# 3 months
	elif [ "$candles_range" -le 262800 ]; then
		dataRange="6"	# 6 months
	else
		dataRange="7"	# all time
	fi
	dataGroup="$candles_interval"
	epoch_milliseconds="$(date +%s%3N)"
	candles_url="https://www.cryptopia.co.nz/Exchange/GetTradePairChart?tradePairId=$trade_pair_id&dataRange=$dataRange&dataGroup=$dataGroup&_=$epoch_milliseconds"
	#candles_url="https://www.cryptopia.co.nz/Exchange/GetTradePairChart?tradePairId=$trade_pair_id&dataRange=$dataRange&dataGroup=$dataGroup"
	
	curl \
	--silent \
	--write-out "\n%{http_code}\n" \
	--header "Content-Type: application/json" \
	--request "GET" \
	"$candles_url" > "$candles"
	
	declare -i http_status	# only allow integer for http status code
	http_status="$(tail -n 1 "$candles")" # last line contains http_code from cURL
	
	if [ "$http_status" -ne 200 ]; then
		echo "Error: HTTP status $http_status from get_candles function"
		return 1
	fi

	candles_open_list="$(grep '^{' "$candles" | jq -r '.Candle | .[] | .[1]')"
	candles_high_list="$(grep '^{' "$candles" | jq -r '.Candle | .[] | .[2]')"
	candles_low_list="$(grep '^{' "$candles" | jq -r '.Candle | .[] | .[3]')"
	candles_close_list="$(grep '^{' "$candles" | jq -r '.Candle | .[] | .[4]')"
}

