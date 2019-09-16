#!/bin/bash

##########################################
# BCTB - Bash Cryptocurrency Trading Bot #
##########################################

# Created by: John Marzella
# Created on: 29/Jan/2018

# Dependencies: (curl jq bc tr)

# terminate script on any errors
#set -e 	# disabled to stop script terminating when there are API errors
#set -x 	# debug mode


###### Config ######
# import config from local file with hardened permissions
cfg="bctb.cfg"
source "$cfg" || { echo "Error: $cfg config file not found"; exit; }
# validate config
cfg_vars="$(grep '=' "$cfg" | awk -F '=' '{print $1}')"
while read -r cfg_var; do
	cfg_val="${!cfg_var}"
	if [ -z "$cfg_val" ]; then
		echo "Error: $cfg_var variable is not set in $cfg"
		exit
	fi
done <<< "$cfg_vars"
if [ "$(echo "$stop_loss_percentage < 0" | bc -l)" -eq 0 ]; then
	echo "Error: stop_loss_percentage variable is not set to a negative value in $cfg"
	exit
fi
echo "$cfg config validated and imported"


####### Functions ######
# import common functions from file
source "bot_functions.sh" || { echo "Error: bot_functions file not found"; exit; }

# import exchange specific functions from file - exchange defined in config
source "exchanges/$exchange" || { echo "Error: exchange file not found"; exit; }

# import strategy functions from file - strategy defined in config
source "strategies/$strategy" || { echo "Error: strategy file not found"; exit; }


###### Script starts here ######

# variables
restore_market_name="market_name.restore"	# used on bot reboot
blacklisted_markets="blacklisted_markets.csv"
tmp_file_template="/tmp/bctb_$exchange-$base_currency-$bot_nickname.XXXXXXXX"
update_duration="$((60 * 60 * market_position_updates))"
duration_increment="$update_duration"
buy_count="0"	# reset counter
sell_count="0"	# reset counter
filled_orders_count="0"	# reset counter
dynamic_base="false"

# main script
bot_start_time_epoch="$(date +%s)"
bot_start_time_long="$(date)"

echo ""
echo "----"
echo "BCTB"
echo "----"
echo ""
echo "Started @ $bot_start_time_long"
echo ""

blacklist_manager "update" || { echo "Error: blacklist_manager function"; exit; }

# set base_currency if volume based alt coin trading is enabled
if [ "$base_currency" = "volume" ]; then
	dynamic_base="true"
	# check for open positions on bot restarts
	if [ -f "$restore_market_name" ]; then
		echo "$restore_market_name file found"
		market_name="$(cat $restore_market_name)"
		if [ -z "$market_name" ]; then
			echo "Warn: $restore_market_name file is empty"
			get_markets || { echo "Error: something went wrong with get_markets before main loop"; exit; }
			echo "Selected $market_name as dynamic market"
		else
			echo "Restored $market_name market name from $restore_market_name file"
			get_trade_history "1" || { echo "Error: something went wrong with get_trade_history before main loop"; exit; }
			if [ "$trade_history_type" = "Buy" ]; then
				echo "Open position found in $trade_history_base_currency market - Trade Id: $trade_history_id"
				base_currency="$trade_history_base_currency"
			else
				get_markets || { echo "Error: something went wrong with get_markets before main loop"; exit; }
				echo "Selected $market_name as dynamic market"
			fi
		fi
	else
		echo "$restore_market_name file not found"
		get_markets || { echo "Error: something went wrong with get_markets before main loop"; exit; }
		echo "Selected $market_name as dynamic market"
	fi
fi

echo ""
echo "Market position info:"
market_position || { echo "Error: something went wrong with market_position before main loop"; exit; }
opening_balance="$(cat << EOF
Opening $market_name market position balances:
Base balance: $base_balance $base_currency
Quote balance: $quote_balance $quote_currency
Last market price: $market_last_price $quote_currency (1 $base_currency)
Total balance in $quote_currency: $quote_total $quote_currency
---
Strategy: $strategy
EOF
)"
echo "$opening_balance"
send_email "Bot started @ $bot_start_time_long" "System uptime: $(uptime) \n\n$opening_balance"
# store opening balances for later profit/loss comparison
opening_quote_total="$quote_total"
#opening_base_total="$base_total"
opening_market_last_price="$market_last_price"

while true
do
	action=""	# clear action variable
	cleanup		# clean up temp files

	echo ""
	echo "---------------------"

	blacklist_manager "update" || continue

	# Volume based base currency (alt coin) selection
	if [ "$dynamic_base" = "true" ]; then
		get_trade_history "1" || continue
		if [ "$trade_history_type" = "Sell" ]; then
			# last Buy position closed (Sold) - choose a new alt coin
			get_markets || continue
		elif [ "$trade_history_type" = "Buy" ]; then
			# Buy position still open, use open position alt coin from Buy trade history
			base_currency="$trade_history_base_currency"
		elif [ "$no_history" = "true" ]; then
			# first run scenario - choose alt coin
			echo "No trade history - selecting alt coin based on highest volume market"
			get_markets || continue
			no_history=""	#unset variable
		else
			echo "Error: could not determine trade history during dynamic_base selection checks"
			sleep 5
			continue
		fi
	fi

	bot_uptime="$(($(date +%s) - bot_start_time_epoch))"
	bot_uptime_hours="$(echo "$bot_uptime / 60 / 60" | bc -l | xargs printf "%.2f")"
	bot_uptime_days="$(echo "$bot_uptime / 60 / 60 / 24" | bc -l | xargs printf "%.2f")"

	# Market position update/report if duration is met
	if [ "$bot_uptime" -ge "$update_duration" ]; then # should change this to use BC to handle decimals
		echo ""
		echo "---------------------"
		echo "Market position info:"
		market_position || continue
		position_balance="$(cat << EOF
Current $market_name market position balances:
Base balance: $base_balance $base_currency
Quote balance: $quote_balance $quote_currency
Total balance in $quote_currency: $quote_total $quote_currency
---
Market prices:
Last market price: $market_last_price $quote_currency (1 $base_currency)
Opening market price: $opening_market_last_price $quote_currency ($opening_market_last_price_percent % diff)
Previous market price ($market_position_updates hours): $previous_market_last_price $quote_currency ($last_market_last_price_percent % diff)
---
Profit and Loss comparison:
Since bot started $quote_currency: $opening_quote_total_pnl ($opening_quote_total_percent % diff)
Last $market_position_updates hours $quote_currency: $last_quote_total_pnl ($last_quote_total_percent % diff)
---
Last Trade:
$trade_history_type @ $trade_history_rate $quote_currency on $trade_history_timestamp
---
Bot running since $bot_start_time_long
Bot running for $bot_uptime_days days ($bot_uptime_hours hours)
---
Strategy: $strategy
EOF
)"
		echo "$position_balance"
		send_email "$market_name market position update" "$position_balance"
		let update_duration=update_duration+duration_increment	# keep adding duration_increment to restart the counter
	fi

	## Should add #bot_uptime somewhere here

	echo ""
	echo "---------------------"
	echo "Trade timestamp: $(date)"
	echo ""

	# Get Trade Pair info
	get_trade_pairs || continue
	echo "Market: $market_name"
	echo "Trade fee: $trade_fee percent"
	echo "Min base trade: $min_base_trade $quote_currency" # API mentions "base", but it's really quote currency...

	# Check open orders
	get_open_orders || continue
	if [ "$no_open_orders" = "true" ]; then
		#echo "No open orders in exchange and/or last trade was successful"
		echo "Hunt for a new trade!"
		#Check trade history
	elif [ "$no_open_orders" = "false" ]; then
		echo "Open order found - $open_order_id - waiting up-to 10 mins in case trading is slow"	# increased from 300 to 600 second to support larger trade volumes
		# should really check the actual order id here...
		old_open_order_id="$open_order_id"
		loop_count="1"
		# increase loop_limit if order if partially filled
		open_order_amount_check="$(echo "$open_order_amount > $open_order_amount_remaining" | bc -l)"	# check for partially filled orders
		if [ "$open_order_amount_check" -eq 1 ]; then
			loop_limit="120"	# 20 mins
		else
			loop_limit="30"	# 5 mins
		fi
		while [ "$loop_count" -le "$loop_limit" ]; do
			sleep 10 #seconds
			get_open_orders || continue
			if [ "$no_open_orders" = "true" ]; then
				echo "Trade completed - Id: $old_open_order_id"
				echo "Start a new trade :)"
				break #exit while loop
			elif [ "$no_open_orders" = "false" ]; then
				echo "Order id: $open_order_id still open"
				action="Cancel"
				# increase loop_limit if order if partially filled
				open_order_amount_check="$(echo "$open_order_amount > $open_order_amount_remaining" | bc -l)"	# check for partially filled orders
				if [ "$open_order_amount_check" -eq 1 ]; then
					loop_limit="120"	# 20 mins
				fi
			else
				echo "Error: unable to determine if open order(s) exist"
				sleep 5
				break
			fi
			let loop_count=loop_count+1
		done
	else
		echo "Error: unable to determine if open order(s) exist"
		sleep 5
		continue
	fi

	# Cancel open orders that are idle for too long
	if [ "$action" = "Cancel" ]; then
		echo "Cancelling open order id: $open_order_id"
		cancel_trade_order "$open_order_id" || continue
		action=""	# clear action variable
		sleep 1
		continue	# restart main while loop
	fi

	# check last order in trade history
	if [ "$filled_orders_count" -gt 1 ]; then
		history_count="$filled_orders_count"
	else
		history_count="1"
	fi
	get_trade_history "$history_count" || continue
	if [ "$no_history" = "true" ]; then
		echo "No trade history - treating as first bot run or new market"
		no_history=""	#unset variable
	else
		# display trade history details
		#echo "Trade history"
		#echo "id: $trade_history_id"
		#echo "type: $trade_history_type"
		#echo "cost: $trade_history_cost $quote_currency"
		#echo "rate: $trade_history_rate $quote_currency"
		#echo "amount: $trade_history_amount $base_currency"
		#echo "timestamp: $trade_history_timestamp"
		echo "Trade history: $trade_history_type @ $trade_history_timestamp"
	fi

	# Get the current market prices
	get_market || continue
	echo "Market Ask: $market_ask $quote_currency"
	echo "Market Bid: $market_bid $quote_currency"

	# Collect data to be used in backtesting and strategy modelling
	collect_backtest_data

	# Trade decision
	# checking trade history type is only relevant for percentage based strategy
	if [ "$trade_history_type" = "Buy" ]; then
		if [ "$strategy" = "percentage.sh" ]; then 	# should move this to percentage.sh source file
			echo "Last trade was Buy, so hopefully next trade is Sell"
			trend_percentage_increase="Buy"
			# count consecutive trades (long trends)
			if [ "$buy_count" -lt 2 ]; then
				buy_count="2"
			fi
			echo "Buy trade count: $buy_count"
			echo "Sell trade count: $sell_count"	# more for log debugging
		fi
		trade_decision || continue
	elif [ "$trade_history_type" = "Sell" ]; then
		if [ "$strategy" = "percentage.sh" ]; then 	# should move this to percentage.sh source file
			echo "Last trade was Sell, so hopefully next trade is Buy"
			trend_percentage_increase="Sell"
			# count consecutive trades (long trends)
			if [ "$sell_count" -lt 2 ]; then
				sell_count="2"
			fi
			echo "Sell trade count: $sell_count"
			echo "Buy trade count: $buy_count"	# more for log debugging
		fi
		trade_decision || continue
	else
		echo "Could not determine last trade type..."
		echo "Checking balances to decide on default trade action..."
		quote_balance_in_base="$(echo "$quote_balance / $market_last_price" | bc -l | xargs printf "%.8f")"
		default_trade_balance_compare="$(echo "$base_balance > $quote_balance_in_base" | bc -l)"
		if [ "$default_trade_balance_compare" -eq 1 ]; then
			action="Sell"
			trade_rate="$market_bid"
			echo "Default trade set to $action"
		else
			if [ "$strategy" = "percentage.sh" ]; then 	# should move this to percentage.sh source file
				# doesn't use market history, so buy immediately
				action="Buy"
				trade_rate="$market_ask"
				echo "Default trade set to $action"
			else
				# use strategy signal to buy to avoid buying at height of market
				trade_history_type="Sell"	# fake historical trade
				echo "Forcing trade history type to Sell and waiting for Buy signal from $strategy strategy"
				trade_decision || continue
			fi
		fi
	fi

	# Trading
	if [ "$action" = "Buy" ]; then
		if [ "$low_buy_balance" = "true" ]; then
			echo "action is $action and low_buy_balance is $low_buy_balance, so exitting current trade loop"
			echo "sleeping for 60 seconds"
			sleep 60
			continue	# restart main while loop
		fi
		trade_type="Buy"
		get_balance "$quote_currency" || continue
		echo "Balance: $available_balance $currency"
		currency_to_trade="$quote_currency"
		trade_calculator || continue
		submit_trade_order || continue
		echo "$market_name" > "$restore_market_name"
	elif [ "$action" = "Sell" ]; then
		if [ "$low_sell_balance" = "true" ]; then
			echo "action is $action and low_sell_balance is $low_sell_balance, so exitting current trade loop"
			echo "sleeping for 60 seconds"
			sleep 60
			continue	# restart main while loop
		fi
		trade_type="Sell"
		get_balance "$base_currency" || continue
		echo "Balance: $available_balance $currency"
		currency_to_trade="$base_currency"
		trade_calculator || continue
		submit_trade_order || continue
	elif [ "$action" = "Hold" ]; then
		echo "Trading thresholds not met"
		echo "Holding on until next run"
	else
		echo "Error: unknown action..."
	fi

	# clean up temp files
	cleanup

	# sleep for 5 seconds between trades to avoid API rate limiting
	sleep 5
done 	# end while loop
