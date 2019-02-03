#!/bin/bash

# Bittrex Exchange - variables & functions
# ----------------------------------------
# API documentation: https://support.bittrex.com/hc/en-us/articles/115003723911-Developer-s-Guide-API

# API rate limiting: TBC?
# All requests use GET method... seems a little dangerous...

#Bittrex v2 api doco
#https://github.com/thebotguys/golang-bittrex-api/wiki/Bittrex-API-Reference-(Unofficial)


# Variables

market_name="$quote_currency-$base_currency"	# must be upper case in config - should validate this!

# Functions

#done - untested
private_api_query() {
	api_group="$1"
	method="$2"
	params="$3"
	api_version="v1.1"
	nonce="$(date +%s%N)"	# added nano seconds to avoid nonce reuse within same second
	url="https://bittrex.com/api/$api_version/$api_group/$method?apikey=$api_key&$params&nonce=$nonce"
	hmacsignature="$(echo -n "$url" | openssl dgst -sha512 -hmac "$api_secret" | sed 's/^.*= //')"
	
	curl \
	--silent \
	--write-out "\n%{http_code}\n" \
	--header "apisign: $hmacsignature" \
	--header "Content-Type: application/json" \
	--request "GET" \
	"$url"
}

# done - works
public_api_query() {
	method="$1"
	get_param1="?$2"
	get_param2="&$3"
	[ -z "$2" ] && get_param1=""
	[ -z "$3" ] && get_param2=""
	url="https://bittrex.com/api/v1.1/public/$method$get_param1$get_param2"

	curl \
	--silent \
	--write-out "\n%{http_code}\n" \
	--header "Content-Type: application/json" \
	--request "GET" \
	"$url"
}

# done
api_response_parser() {
	response="$1"
	calling_function="$2"
	rsp_success="$(grep '^{' "$response" | jq -r .success)"
	rsp_error="$(grep '^{' "$response" | jq -r .message)"
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

# /public/getticker & /public/getmarketsummary
get_market() {
	market="$(mktemp "$tmp_file_template")"
	public_api_query getticker "market=$market_name" > "$market"
	api_response_parser "$market" "get_market" || return 1
	market_ask="$(grep '^{' "$market" | jq -r '.result.Ask' | xargs printf "%.8f")"
	market_bid="$(grep '^{' "$market" | jq -r '.result.Bid' | xargs printf "%.8f")"
	market_last_price="$(grep '^{' "$market" | jq -r '.result.Last' | xargs printf "%.8f")"

	api_value_validator "number" "$market_ask" "get_market ask" || return 1
	api_value_validator "number" "$market_bid" "get_market bid" || return 1

	market_summary="$(mktemp "$tmp_file_template")"
	public_api_query getmarketsummary "market=$market_name" > "$market_summary"
	api_response_parser "$market_summary" "get_market_summary" || return 1
	market_volume="$(grep '^{' "$market_summary" | jq -r '.result[].Volume' | xargs printf "%.8f")"	# base (alt coin) volume
	market_base_volume="$(grep '^{' "$market_summary" | jq -r '.result[].BaseVolume' | xargs printf "%.8f")"	# quote (BTC) volume
	#market_open_buy_orders="$(grep '^{' "$market_summary" | jq -r '.result[].OpenBuyOrders' | xargs printf "%.8f")"
	#market_open_buy_orders="$(grep '^{' "$market_summary" | jq -r '.result[].OpenSellOrders' | xargs printf "%.8f")"
}

# GetMarkets
get_markets() {
	# used to decide on market to trade based on market base volumes
	markets="$(mktemp "$tmp_file_template")"
	markets_filtered="$(mktemp "$tmp_file_template")"
	markets_blacklist_cmd="$(mktemp "$tmp_file_template")"
	public_api_query getmarketsummaries > "$markets"
	api_response_parser "$markets" "get_markets" || return 1

	# filter out blacklisted and non-BTC markets
	blacklist_manager "list" || return 1
	if [ "$blacklist_empty" = "true" ]; then
		grep '^{' "$markets" | jq -r --arg quote_currency "$quote_currency-" '.result[] | select(.MarketName | contains($quote_currency))' > "$markets_filtered"
	else
		# hack to workaround jq not accepting commands stored in variables
		echo "grep '^{' $markets | jq -r '.result[] | select(.MarketName | contains(\"$quote_currency-\")) | select(.MarketName | $blacklist_contains | not)'" > "$markets_blacklist_cmd"
		bash "$markets_blacklist_cmd" > "$markets_filtered"
	fi

	previous_market_name="$market_name"
	market_volume="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .Volume' "$markets_filtered" | xargs printf "%.8f")"	# base (alt coin) volume
	market_base_volume="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .BaseVolume' "$markets_filtered" | xargs printf "%.8f")"	# quote (BTC) volume
	#market_buy_base_volume="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .BuyBaseVolume' "$markets_filtered" | xargs printf "%.8f")"
	#market_sell_base_volume="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .SellBaseVolume' "$markets_filtered" | xargs printf "%.8f")"
	market_name="$(jq -s -r 'sort_by(.BaseVolume) | .[-1] | .MarketName' "$markets_filtered")"	# select market with largest base volume
	base_currency="$(echo "$market_name" | awk -F '-' '{print $2}')"
}

# /public/getmarkets
get_trade_pairs() {
	trade_pairs="$(mktemp "$tmp_file_template")"
	public_api_query getmarkets > "$trade_pairs"
	api_response_parser "$trade_pairs" "get_trade_pairs" || return 1
	trade_fee="0.25"	# hardcoded based on https://support.bittrex.com/hc/en-us/articles/115000199651-What-fees-does-Bittrex-charge-
	# convert base to quote to allign with cryptopia minimum limits logic in the bot
		# see https://support.bittrex.com/hc/en-us/articles/115003004171-What-are-my-trade-limits-
		#min_trade_size="$(grep '^{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.result[] | select(.MarketName==$market_name) | .MinTradeSize')"
		#get_market
		#min_base_trade="$(echo "$min_trade_size * $market_last_price" | bc -l | xargs printf "%.8f")"
		min_base_trade="0.0005"	# hardcoded based on "DUST_TRADE_DISALLOWED_MIN_VALUE_50K_SAT" error https://support.bittrex.com/hc/en-us/articles/115000240791-Error-Codes-Troubleshooting-common-error-codes
	trade_pair_status="$(grep '^{' "$trade_pairs" | jq -r --arg market_name "$market_name" '.result[] | select(.MarketName==$market_name) | .IsActive')"
	# check if trade fee has changed from expected amount
	compare_trade_fee="$(echo "$trade_fee == $expected_trade_fee" | bc -l)"
	if [ "$compare_trade_fee" -ne 1 ]; then
		echo "WARN: Trade fee has changed!"
		echo "Expected fee: $expected_trade_fee"
		echo "Current fee: $trade_fee"
		send_email "WARN: Trade fee has changed!" "Expected fee: $expected_trade_fee \nCurrent fee: $trade_fee"
	fi
	# check trade pair status
	if [ "$trade_pair_status" != "true" ]; then
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
	#market_orders_buy="$(grep '^{' "$market_orders" | jq -r '.Data.Buy[].Price')"
	#market_orders_sell="$(grep '^{' "$market_orders" | jq -r '.Data.Sell[].Price')"
	#market_buy_average="$(echo "$market_orders_buy" | jq -r -s 'add/length' | xargs printf "%.8f")"
	#market_sell_average="$(echo "$market_orders_sell" | jq -r -s 'add/length' | xargs printf "%.8f")"
#}

# /public/getmarkethistory
get_market_history() {
	# add all prices from a given time period and divide by the number of prices to work out the average
	market_history_hours="24"	# currently not used by bittrex - time period not accepted - last 100 results returned everytime
	market_history="$(mktemp "$tmp_file_template")"
	public_api_query getmarkethistory "market=$market_name" > "$market_history"
	api_response_parser "$market_history" "get_market_history" || return 1
	market_history_prices="$(grep '^{' "$market_history" | jq -r '.result[].Price' | head -n "$sma_period")"	# list of all buy & sell prices
	market_history_average_price="$(echo "$market_history_prices" | jq -r -s 'add/length' | xargs printf "%.8f")"
	market_history_trade_count="$(echo "$market_history_prices" | wc -l)"
	if [ "$market_history_trade_count" -lt "$sma_period" ]; then
		echo "Error: Trade count ($market_history_trade_count) is less than expected SMA period ($sma_period)"
		send_email "Error: Trade count not met!" "Trade count: $market_history_trade_count \nSMA period config: $sma_period" "$market_history"
		return 1	# avoid incorrect averages when market count not met
	fi
}


# Private API calls

# /account/getbalance
get_balance() {
	currency="$1"
	balance_currency="currency=$currency"
	balance="$(mktemp "$tmp_file_template")"
	if [ -z "$currency" ]; then
		private_api_query account getbalances > "$balance"
	else
		private_api_query account getbalance "$balance_currency" > "$balance"
	fi
### api value validator should probably be used here, but how to determine if the balance is truely zero?
	api_response_parser "$balance" "get_balance" || return 1
	bittrex_balance="$(grep '^{' "$balance" | jq -r '.result.Available')"
	# handle empty balances in bittrex exchange
	if [ "$available_balance" = "" ]; then
		available_balance="0"
	elif [ "$available_balance" = "null" ]; then
		available_balance="0"
	else
		available_balance="$(echo "$bittrex_balance" | xargs printf "%.8f")"
	fi
}

# /market/getopenorders
get_open_orders() {
	tradepair="market=$market_name"
	open_orders="$(mktemp "$tmp_file_template")"
	private_api_query market getopenorders "$tradepair" > "$open_orders"
	api_response_parser "$open_orders" "get_open_orders" || return 1
	##### need to handle multiple open orders?
	open_order_check="$(grep '^{' "$open_orders" | jq -r '.result[]')"
	if [ -z "$open_order_check" ]; then
		no_open_orders="true"
		echo "No open order(s) for $market_name market"
	else
		no_open_orders="false"
		echo "Open order(s) found for $market_name market"
		open_order_id="$(grep '^{' "$open_orders" | jq -r '.result[].OrderUuid')"
		open_order_amount="$(grep '^{' "$open_orders" | jq -r '.result[].Quantity')"
		open_order_amount_remaining="$(grep '^{' "$open_orders" | jq -r '.result[].QuantityRemaining')"
		open_order_amount_filled="$(echo "$last_trade_amount - $open_order_amount_remaining" | bc -l | xargs printf "%.8f")"
	fi
}

# /market/buylimit & /market/selllimit - done - untested
submit_trade_order() {
	trade="market=$market_name&rate=$trade_rate&quantity=$trade_amount"
	submit_trade="$(mktemp "$tmp_file_template")"
	if [ "$trade_type" = "Buy" ]; then
		private_api_query market buylimit "$trade" > "$submit_trade"
	elif [ "$trade_type" = "Sell" ]; then
		private_api_query market selllimit "$trade" > "$submit_trade"
	fi
	api_response_parser "$submit_trade" "submit_trade_order" || return 1
	last_order_id="$(grep '^{' "$submit_trade" | jq -r '.result.uuid')"
	last_trade_type="$trade_type"	
	last_trade_cost="$trade_total_cost"
	#last_trade_rate="$trade_rate"	# not used 
	last_trade_amount="$trade_amount"
	filled_orders="NA"	##### not available from this bittrex api call
	filled_orders_count="0"	##### not available from this bittrex api call
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

# /market/cancel - done - untested
cancel_trade_order() {
	order_id="$1"
	trade="uuid=$order_id"
	cancel_trade="$(mktemp "$tmp_file_template")"
	private_api_query market cancel "$trade" > "$cancel_trade"
	api_response_parser "$cancel_trade" "cancel_trade_order" || return 1
	cancel_trade_data="$(grep '^{' "$cancel_trade" | jq -r '.')"
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

# /account/getorderhistory - done
get_trade_history() {
	count="$1"
	past_trades="market=$market_name"
	trade_history="$(mktemp "$tmp_file_template")"
	private_api_query account getorderhistory "$past_trades" > "$trade_history"
	api_response_parser "$trade_history" "get_trade_history" || return 1
	emtpy_history="$(grep '^{' "$trade_history" | jq -r '.result[]')"
	if [ "$emtpy_history" = "" ]; then
		no_history="true"
		echo "no trade history found"
	else
		trade_history_id="$(grep '^{' "$trade_history" | jq -r '.result[0].OrderUuid')"
		trade_history_market="$(grep '^{' "$trade_history" | jq -r '.result[0].Exchange')"
		trade_history_base_currency="$(echo "$trade_history_market" | awk -F '-' '{print $2}')"
		trade_history_type_bittrex="$(grep '^{' "$trade_history" | jq -r '.result[0].OrderType')"
		trade_history_cost="$(grep '^{' "$trade_history" | jq -r '.result[0].Price' | xargs printf "%.8f")"
		trade_history_rate="$(grep '^{' "$trade_history" | jq -r '.result[0].Limit' | xargs printf "%.8f")"
		trade_history_quantity="$(grep '^{' "$trade_history" | jq -r '.result[0].Quantity' | xargs printf "%.8f")"
		trade_history_quantity_remaining="$(grep '^{' "$trade_history" | jq -r '.result[0].QuantityRemaining' | xargs printf "%.8f")"
		trade_history_amount="$(echo "$trade_history_quantity - $trade_history_quantity_remaining" | bc -l)" # USE FILLED ORDERS AMOUNT!
		trade_history_timestamp="$(grep '^{' "$trade_history" | jq -r '.result[0].TimeStamp')"

		###### probably need to handle cancelled orders that have 0 trade amount after minusing quantity remaining....?

		# Align trade types with bot & cryptopia
		if [ "$trade_history_type_bittrex" = "LIMIT_SELL" ]; then
			trade_history_type="Sell"
		elif [ "$trade_history_type_bittrex" = "LIMIT_BUY" ]; then
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

## Unofficial web calls - not part of public or private APIs ##
# https://github.com/thebotguys/golang-bittrex-api/wiki/Bittrex-API-Reference-(Unofficial)

# Get candles for long term moving average calcs
get_candles() {
#URL: https://international.bittrex.com/Api/v2.0/pub/market/GetTicks
#METHOD: GET
#PARAMS: marketName:string, tickInterval:string, _:int
#EXAMPLE: https://international.bittrex.com/Api/v2.0/pub/market/GetTicks?marketName=BTC-CVC&tickInterval=thirtyMin&_=1500915289433
#COMMENT: Probably _ is a timestamp. tickInterval must be in [“oneMin”, “fiveMin”, “thirtyMin”, “hour”, “day”].

# _ timestamp param doesn't appear to be required for requests

	# candle timestamps are in UTC/timezone: 2018-11-30T23:19:00
	# append -00:00 to the timestamp so gnu date knows it's in UTC
	# then convert to epoch: date -d "2018-11-30T23:19:00-00:00" +"%s"
	# might not need to care about the timestamp though... oldest result appears to be 10 days old... just count required range?

	candles="$(mktemp "$tmp_file_template")"
	dataRange=""	# bittrex API doesn't accept a range
	# convert candles_interval minutes to bittrex tickInterval param (rounds up)
	if [ "$candles_interval" -le 1 ]; then
		dataGroup="oneMin"		# 1 minute
	elif [ "$candles_interval" -le 5 ]; then
		dataGroup="fiveMin"		# 5 minutes
	elif [ "$candles_interval" -le 30 ]; then
		dataGroup="thirtyMin"	# 30 minutes
	elif [ "$candles_interval" -le 60 ]; then
		dataGroup="hour"		# 1 hour
	elif [ "$candles_interval" -le 1440 ]; then
		dataGroup="day"			# 1 day
	fi
	epoch_milliseconds="$(date +%s%3N)"
	candles_url="https://international.bittrex.com/Api/v2.0/pub/market/GetTicks?marketName=$market_name&tickInterval=$dataGroup&_=$epoch_milliseconds"
	#candles_url="https://international.bittrex.com/Api/v2.0/pub/market/GetTicks?marketName=$market_name&tickInterval=$dataGroup"

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

	candles_open_list="$(grep '^{' "$candles" | jq -r '.result[].O')"
	candles_open_average="$(echo "$candles_open_list" | tail -n "$sma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	candles_high_list="$(grep '^{' "$candles" | jq -r '.result[].H')"
	candles_high_average="$(echo "$candles_high_list" | tail -n "$sma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	candles_low_list="$(grep '^{' "$candles" | jq -r '.result[].L')"
	candles_low_average="$(echo "$candles_low_list" | tail -n "$sma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	candles_close_list="$(grep '^{' "$candles" | jq -r '.result[].C')"
	candles_close_average="$(echo "$candles_close_list" | tail -n "$sma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
}
