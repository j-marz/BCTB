#!/bin/bash

# Common functions - not exchange specific

send_email() {
	email_subject="$1"
	email_body="$2"
	email_attachment="$3"
	attach_switch="-A"
	[ -z "$3" ] && email_attachment="" && attach_switch=""
	email_timestamp="$(date)"
	echo -e "$email_body \n\nTimestamp: $email_timestamp" | mail -s "$email_subject" \
		"$attach_switch" "$email_attachment" \
		"$recipient_email" \
		-a From:"BCTB-$exchange-$base_currency" \
		-a Content-Type:"text/plain"
}

api_value_validator() {
	# check if api is returning wrong values that will cause bad trades (e.g. negatives or zeros)
	validation_type="$1"
	validation_value="$2"
	calling_function="$3"
	string_whitelist=(Buy Sell OK true false)	# strings need to be verified... Maybe this should be passed to function as an arg?
	if [ "$validation_type" = "number" ]; then
		number_validation="$(echo "$validation_value > 0" | bc -l)"
		if [ "$number_validation" -ne 1 ]; then
			echo "ERROR: API returned negative or zero value for $calling_function"
			send_email "ERROR: API returned negative or zero value for $calling_function" "Type: $validation_type \nValue: $validation_value"
			sleep 60
			validation_type=""	# clear variable
			validation_value=""	# clear variable
			calling_function=""	# clear variable
			return 1	# restart main trading loop
		fi
	elif [ "$validation_type" = "null" ]; then
		# check if string is null
		if [ "$validation_value" = "" ] || [ "$validation_value" = "null" ]; then
			echo "ERROR: API returned null value for $calling_function"
			send_email "ERROR: API returned null value for $calling_function" "Type: $validation_type \nValue: $validation_value"
			sleep 60
			validation_type=""	# clear variable
			validation_value=""	# clear variable
			calling_function=""	# clear variable
			return 1	# restart main trading loop
		fi
	elif [ "$validation_type" = "string" ]; then
		# check if string exists in whitelist
		for string in "${string_whitelist[@]}"; do
			if [ "$string" = "$validation_value" ]; then
				value_in_string_array="true"
			fi
		done
		if [ "$value_in_string_array" != "true" ]; then
			echo "ERROR: API returned unknown string for $calling_function"
			send_email "ERROR: API returned unknown string for $calling_function" "Type: $validation_type \nValue: $validation_value"
			sleep 60
			validation_type=""	# clear variable
			validation_value=""	# clear variable
			calling_function=""	# clear variable
			value_in_string_array=""	# clear variable
			return 1	# restart main trading loop
		fi
	else
		echo "ERROR: Unknown API validation type for $calling_function"
		send_email "ERROR: Unknown API validation type for $calling_function" "Type: $validation_type \nValue: $validation_value"
		sleep 60
		validation_type=""	# clear variable
		validation_value=""	# clear variable
		calling_function=""	# clear variable
		return 1 	# restart main trading loop
	fi
	#echo "API response values validated for $calling_function"	# disabled to avoid log spam
	validation_type=""	# clear variable
	validation_value=""	# clear variable
	calling_function=""	# clear variable
	value_in_string_array=""	# clear variable
}

cleanup() {
	temp_files="$(echo "$tmp_file_template" | awk -F "." '{print $1"."$2}')"	# expects "." in exchange name
	rm -f "$temp_files".*
}

trade_calculator() {
	passthrough_balance="$available_balance"	# hack to fix available_balance always being quote_balance when same action as last trade
	if [ -z "$trade_history_type" ]; then	# Default/first trade
		echo "Calculating default trade amounts"
		balance_amount="$(echo "$passthrough_balance * ($coin_percentage / 100)" | bc -l | xargs printf "%.8f")"
		echo "Balance amount to be used: $balance_amount $currency"
		if [ "$action" = "Buy" ]; then
			trade_amount="$(echo "$balance_amount / $trade_rate" | bc -l | xargs printf "%.8f")"
		elif [ "$action" = "Sell" ]; then
			trade_amount="$balance_amount"
		else
			echo "Error: Unknown action: $action, in default trade scenario during trade_calculator"
			return 1
		fi
	# Force coin_percentage for MA strategies to maximise profits
	elif [ "$strategy" = "sma.sh" ] || [ "$strategy" = "dmac.sh" ] || [ "$strategy" = "tmac.sh" ]; then
		echo "MA strategy trade calculator"
		if [ "$action" = "Buy" ]; then
			echo "Using $coin_percentage percent of $quote_currency balance for Buy trade"
			get_balance "$quote_currency" || return 1
			balance_amount="$(echo "$available_balance * ($coin_percentage / 100)" | bc -l | xargs printf "%.8f")"
			trade_amount="$(echo "$balance_amount / $trade_rate" | bc -l | xargs printf "%.8f")"
			echo "Trade amount: $trade_amount $base_currency"
		elif [ "$action" = "Sell" ]; then
			if [ "$ma_sell" = "last_trade" ]; then
				# use trade_history_amount instead of last_trade_amount from memory to handle cancelled trades
				trade_amount_with_fee="$(echo "$trade_history_amount + ($trade_history_amount * ($trade_fee / 100))" | bc -l | xargs printf "%.8f")"
				trade_amount_without_fee="$(echo "$trade_history_amount - ($trade_history_amount * ($trade_fee / 100))" | bc -l | xargs printf "%.8f")"
				trade_amount_check="$(echo "$trade_amount_with_fee < $balance_amount" | bc -l)"
				if [ "$trade_amount_check" -eq 1 ]; then
					echo "Using last trade amount of from exchange history for Sell trade"
					trade_amount="$trade_history_amount"
				else
					echo "Using last trade amount of from exchange history minus fee amount for Sell trade"
					trade_amount="$trade_amount_without_fee"
				fi
			elif [ "$ma_sell" = "coin_percentage" ]; then
				# use coin_percentage type for ma_sell
				get_balance "$base_currency" || return 1
				balance_amount="$(echo "$available_balance * ($coin_percentage / 100)" | bc -l | xargs printf "%.8f")"
				trade_amount="$balance_amount"
				echo "Using $coin_percentage percent of $base_currency balance for Sell trade"
			else
				# default - use maximum amount for trade
				get_balance "$base_currency" || return 1
				if [ "$sell_amount_requires_fee" = "false" ]; then
					trade_amount="$available_balance"
					echo "Using max balance of $base_currency balance for Sell trade ($available_balance)"
				else
					trade_amount_without_fee="$(echo "$available_balance - ($available_balance * ($trade_fee / 100))" | bc -l | xargs printf "%.8f")"
					trade_amount="$trade_amount_without_fee"
					echo "Using max balance of $base_currency balance minus fee amount for Sell trade"
				fi
			fi
			echo "Trade amount: $trade_amount $base_currency"
		else
			echo "Error: Unknown action: $action, in MA strategy trade scenario during trade_calculator"
			return 1
		fi
	elif [ "$trade_history_type" != "$action" ]; then	# avoid over or under selling current trade
		echo "Last trade action was $trade_history_type and new trade action is $action"
		##### DON'T USE LAST_TRADE_AMOUNT FROM MEMORY AS IT'S NOT AWARE OF CANCELLED ORDERS #####
		# use last trade amount from memory to split orders - only useful if bot has not been interrupted and memory intact
		#if [ -z "$last_trade_amount" ]; then 
			echo "Using last trade amount of $trade_history_amount $base_currency from exchange history"
			trade_amount="$trade_history_amount"
		#else
			#echo "Using last trade amount of $last_trade_amount $base_currency from bot memory"
			#trade_amount="$last_trade_amount"
		#fi
	else
		echo "Same action as last trade, so using ratio percentage of balance for this trade"
		# calculate percentage and ratio of coin balances to adjust trade amount - use base currency for coin totals
		get_balance "$base_currency" || return 1
		base_balance="$available_balance"
		get_balance "$quote_currency" || return 1
		quote_balance="$(echo "$available_balance / $trade_rate" | bc -l | xargs printf "%.8f")"	# in base currency
		base_total="$(echo "$quote_balance + $base_balance" | bc -l | xargs printf "%.8f")"
		base_balance_percent="$(echo "($base_balance / $base_total) * 100" | bc -l | xargs printf "%.8f")"
		quote_balance_percent="$(echo "($quote_balance / $base_total) * 100" | bc -l | xargs printf "%.8f")"
		if [ "$currency_to_trade" = "$quote_currency" ]; then
			echo "$quote_currency balance makes up $quote_balance_percent% of total base balance $base_total $base_currency"
			quote_balance_ratio="$(echo "$quote_balance_percent / $base_balance_percent" | bc -l | xargs printf "%.8f")"
			quote_coin_percentage="$(echo "$coin_percentage / $quote_balance_ratio" | bc -l | xargs printf "%.8f")"
			quote_coin_percentage_check="$(echo "$quote_coin_percentage < $coin_percentage" | bc -l)"	# handle floats
			if [ "$quote_coin_percentage_check" -eq 1 ]; then
				echo "using $quote_currency balance ratio percentage to avoid over trading - $quote_coin_percentage%"
				trade_amount="$(echo "$quote_balance * ($quote_coin_percentage / 100)" | bc -l | xargs printf "%.8f")"
			else
				# use the max coin percentage amount
				echo "using max coin percentage amount of $coin_percentage%"
				trade_amount="$(echo "$quote_balance * ($coin_percentage / 100)" | bc -l | xargs printf "%.8f")"
			fi
		elif [ "$currency_to_trade" = "$base_currency" ]; then
			echo "$base_currency balance makes up $base_balance_percent% of total base balance $base_total $base_currency"
			base_balance_ratio="$(echo "$base_balance_percent / $quote_balance_percent" | bc -l | xargs printf "%.8f")"
			base_coin_percentage="$(echo "$coin_percentage / $base_balance_ratio" | bc -l | xargs printf "%.8f")"
			base_coin_percentage_check="$(echo "$base_coin_percentage < $coin_percentage" | bc -l)"	# handle floats
			if [ "$base_coin_percentage_check" -eq 1 ]; then
				echo "using $base_currency balance ratio percentage to avoid over trading - $base_coin_percentage%"
				trade_amount="$(echo "$base_balance * ($base_coin_percentage / 100)" | bc -l | xargs printf "%.8f")"
			else
				# use the max coin percentage amount
				echo "using max coin percentage amount of $coin_percentage%"
				trade_amount="$(echo "$base_balance * ($coin_percentage / 100)" | bc -l | xargs printf "%.8f")"
			fi
		else
			echo "Error: unknown currency $currency_to_trade during trade_calculator"
			return 1
		fi
	fi
	trade_coin_cost="$(echo "$trade_amount * $trade_rate" | bc -l | xargs printf "%.8f")"
	trade_amount_check="$(echo "$trade_coin_cost >= $min_base_trade" | bc -l)"	# this also covers check if not enough coins
	if [ "$trade_amount_check" -eq 1 ]; then
		echo "Ready to trade"
		trade_fee_cost="$(echo "$trade_amount * ($trade_fee / 100) * $trade_rate" | bc -l | xargs printf "%.8f")"
		trade_total_cost="$(echo "$trade_coin_cost + $trade_fee_cost" | bc -l | xargs printf "%.8f")"
		echo "Trade amount cost: $trade_coin_cost $quote_currency"
		echo "Fee amount: $trade_fee_cost $quote_currency"
		echo "Total cost of trade: $trade_total_cost $quote_currency"
	else
		# Try minimum trade cost if balance is too low
		echo "$trade_coin_cost $quote_currency doesn't meet minimum trade cost of $min_base_trade $quote_currency"
		echo "Checking if we have enough for minimum trade cost..."
		minimum_trade="$(echo "$min_base_trade + ($min_base_trade * 1 / 100)" | bc -l | xargs printf "%.8f")"	# add 1% to minimum base trade to avoid errors
		trade_amount="$(echo "$minimum_trade / $trade_rate" | bc -l | xargs printf "%.8f")"
		trade_coin_cost="$minimum_trade"
		trade_fee_cost="$(echo "$trade_amount * ($trade_fee / 100) * $trade_rate" | bc -l | xargs printf "%.8f")"
		trade_total_cost="$(echo "$trade_coin_cost + $trade_fee_cost" | bc -l | xargs printf "%.8f")"
		if [ "$trade_type" = "Buy" ]; then
			trade_amount_check="$(echo "$trade_total_cost < $passthrough_balance" | bc -l)"
			if [ "$trade_amount_check" -eq 1 ]; then
				echo "We have enough for minimum trade :)"
				echo "Trade amount cost: $trade_coin_cost $quote_currency"
				echo "Fee amount: $trade_fee_cost $quote_currency"
				echo "Total cost of trade: $trade_total_cost $quote_currency"
			else
				echo "Error: not enough coins to trade"
				send_email "Not enough coins - $currency" "Available balance: $passthrough_balance $currency\nTrade amount: $trade_amount $base_currency \nTrade amount cost: $trade_coin_cost $quote_currency \nTrade fee cost: $trade_fee_cost \nTrade total cost: $trade_total_cost \nMin base trade amount: $min_base_trade $quote_currency"
				low_buy_balance="true"
				sleep 5
				return 1	# restart main while loop
			fi
		elif [ "$trade_type" = "Sell" ]; then
			trade_total_base_coins="$(echo "$trade_total_cost / $trade_rate" | bc -l | xargs printf "%.8f")"
			trade_amount_check="$(echo "$trade_total_base_coins < $passthrough_balance" | bc -l)"
			if [ "$trade_amount_check" -eq 1 ]; then
				echo "We have enough for minimum trade :)"
				echo "Trade amount cost: $trade_coin_cost $quote_currency"
				echo "Fee amount: $trade_fee_cost $quote_currency"
				echo "Total cost of trade: $trade_total_cost $quote_currency"
			else
				echo "Error: not enough coins to trade"
				send_email "Not enough coins - $currency" "Available balance: $passthrough_balance $currency\nTrade amount: $trade_amount $base_currency \nTrade amount cost: $trade_coin_cost $quote_currency \nTrade fee cost: $trade_fee_cost \nTrade total cost: $trade_total_cost \nMin base trade amount: $min_base_trade $quote_currency"
				low_sell_balance="true"
				sleep 5
				return 1	# restart main while loop
			fi
		else
			echo "Error in trade_calculator function"
			sleep 5
			return 1	# restart main while loop
		fi
	fi
}

market_position() {
	get_balance "$base_currency" || return 1
	base_balance="$available_balance"
	get_balance "$quote_currency" || return 1
	quote_balance="$available_balance"
	get_market || return 1
	quote_total="$(echo "($base_balance * $market_last_price) + $quote_balance" | bc -l | xargs printf "%.8f")"
	#base_total="$(echo "($quote_balance / $market_last_price) + $base_balance" | bc -l | xargs printf "%.8f")"
	if [ ! -z "$opening_quote_total" ]; then
		opening_quote_total_pnl="$(echo "$quote_total - $opening_quote_total" | bc -l | xargs printf "%.8f")"
		opening_quote_total_percent="$(echo "(($quote_total - $opening_quote_total) / $opening_quote_total) * 100" | bc -l | xargs printf "%.8f")"
	fi
	#if [ ! -z "$opening_base_total" ]; then
	#	opening_base_total_pnl="$(echo "$base_total - $opening_base_total" | bc -l | xargs printf "%.8f")"
	#	opening_base_total_percent="$(echo "(($base_total - $opening_base_total) / $opening_base_total) * 100" | bc -l | xargs printf "%.8f")"
	#fi
	if [ ! -z "$last_quote_total" ]; then
		last_quote_total_pnl="$(echo "$quote_total - $last_quote_total" | bc -l | xargs printf "%.8f")"
		last_quote_total_percent="$(echo "(($quote_total - $last_quote_total) / $last_quote_total) * 100" | bc -l | xargs printf "%.8f")"
	fi
	#if [ ! -z "$last_base_total" ]; then
	#	last_base_total_pnl="$(echo "$base_total - $last_base_total" | bc -l | xargs printf "%.8f")"
	#	last_base_total_percent="$(echo "(($base_total - $last_base_total) / $last_base_total) * 100" | bc -l | xargs printf "%.8f")"
	#fi
	# set current totals to last_*_totals for next run
	last_quote_total="$quote_total"
	#last_base_total="$base_total"
	# market rates percentage changes
	if [ ! -z "$opening_market_last_price" ]; then
		if [ "$base_currency" = "$last_market_position_base_currency" ]; then
			opening_market_last_price_percent="$(echo "(($market_last_price - $opening_market_last_price) / $opening_market_last_price) * 100" | bc -l | xargs printf "%.8f")"
		else
			# when base currency changes in volume based trading
			opening_market_last_price="$market_last_price"
			opening_market_last_price_percent="0"
		fi
	fi
	if [ ! -z "$last_market_last_price" ]; then
		if [ "$base_currency" = "$last_market_position_base_currency" ]; then
			last_market_last_price_percent="$(echo "(($market_last_price - $last_market_last_price) / $last_market_last_price) * 100" | bc -l | xargs printf "%.8f")"
		else
			# when base currency changes in volume based trading
			last_market_last_price_percent="0"
		fi
	fi
	previous_market_last_price="$last_market_last_price"
	last_market_last_price="$market_last_price"
	last_market_position_base_currency="$base_currency"
}

trade_position_age () {
	current_time_epoch="$(date +"%s")"
	max_position_age_seconds="$(echo "$max_position_age * 24 * 60 * 60" | bc -l)"	# convert days config variable to seconds
	trade_position_time_epoch="$(date --date="$trade_history_timestamp" +"%s")"	# requires timestamp in correct format
	trade_position_time_diff="$(echo "$current_time_epoch - $trade_position_time_epoch" | bc -l)"
	trade_position_age_days="$(echo "$trade_position_time_diff / 60 / 60 / 24" | bc -l | xargs printf "%.2f")"
	trade_position_time_compare="$(echo "$trade_position_time_diff >= $max_position_age_seconds" | bc -l)"
	if [ "$trade_position_time_compare" -eq 1 ]; then
		echo "Warn: Max position age ($max_position_age days) has been met"
		# NOTE: sending an email here will cause a lot of spam unless some action is taken to exit the position
		if [ "$low_sell_balance" = "true" ]; then
				echo "WARN: Balance is too low to initiate trade position age sell - sleeping for 60 seconds"
				sleep 60	# wait for market to recover?
				return 1
			else
				send_email "Warn: Max trade position age met for $market_name" "Age: $trade_position_age_days days \nTrade timestamp: $trade_history_timestamp"
				trade_position_expired="true"
			fi
	elif [ "$trade_position_time_compare" -eq 0 ]; then
		trade_position_expired="false"
	else
		echo "Error: can't compare trade position age"
		sleep 5
		return 1
	fi
}

# TODO: need to check if immediate buy will occur after stop loss due to MA strategy and avoid selling in this case.
stop_loss() {
	position_percentage="$(echo "(($market_bid - $trade_history_rate) / $trade_history_rate) * 100" | bc -l | xargs printf "%.8f")"
	stop_loss_compare="$(echo "$position_percentage <= $stop_loss_percentage" | bc -l)"
		if [ "$stop_loss_compare" -eq 1 ]; then
			echo "Warn: Stop Loss threshold of $stop_loss_percentage percent met"
			echo "Position: $position_percentage percent"
			if [ "$low_sell_balance" = "true" ]; then
				echo "WARN: Balance is too low to initiate stop loss sell - sleeping for 60 seconds"
				sleep 60	# wait for market to recover?
				return 1
			else
				echo "Waiting 2 mins in case of temporary market dip before initiating stop loss"
				sleep 120
				get_market || return 1	# update market bid
				position_percentage="$(echo "(($market_bid - $trade_history_rate) / $trade_history_rate) * 100" | bc -l | xargs printf "%.8f")"
				stop_loss_compare="$(echo "$position_percentage <= $stop_loss_percentage" | bc -l)"
				if [ "$stop_loss_compare" -eq 1 ]; then
					send_email "Warn: Stop Loss threshold of $stop_loss_percentage percent met after waiting" "Position: $position_percentage percent"
					stop_loss_sell="true"
				elif [ "$stop_loss_compare" -eq 0 ]; then
					stop_loss_sell="false"
				else
					echo "Error: can't compare stop loss percentage"
					sleep 5
					return 1
				fi
			fi
		elif [ "$stop_loss_compare" -eq 0 ]; then
			stop_loss_sell="false"
		else
			echo "Error: can't compare stop loss percentage"
			sleep 5
			return 1
		fi

		# blacklist markets with extreme volatility for 24 hours
		if [ "$base_currency" = "volume" ] && [ "$previous_market_name" != "$market_name" ]; then
			# reset counter when market changes in dynamic volume based trading config
			stop_loss_counter="0"
		fi
		if [ "$stop_loss_sell" = "true" ]; then
			let stop_loss_counter=stop_loss_counter+1
			if [ "$stop_loss_counter" -eq 2 ]; then
				#TODO: set config to avoid using blacklist when using static trade pair and not dynamic volume mode
				blacklist_manager "add" "$market_name" "24" "consecutive stop loss triggers" || return 1
			fi
		fi
}

blacklist_manager() {
	blacklist_method="$1"
	blacklist_market="$2"
	blacklist_expiry_hours="$3"
	blacklist_reason="$4"
	[ -z "$blacklist_expiry_hours" ] && blacklist_expiry_hours="1"	# default to 1 hour if arg not passed
	blacklist_timestamp="$(date +%s)"	# in seconds
	blacklist_max_age="$((60 * 60 * blacklist_expiry_hours + blacklist_timestamp))"	# in seconds
	blacklist_temp="$(mktemp "$tmp_file_template")"
	# CSV structure: market, added timestamp, expiry timestamp
	if [ "$blacklist_method" = "add" ]; then
		if [ ! -f "$blacklisted_markets" ]; then
			echo "$blacklist_market,$blacklist_timestamp,$blacklist_max_age" >> "$blacklisted_markets"
			send_email "INFO: $blacklist_market added to blacklist" "Market: $blacklist_market \nMarket status: $trade_pair_status \nBlacklist reason: $blacklist_reason \nBlacklist expiry (hours): $blacklist_expiry_hours"
		else
			if grep -q "$blacklist_market" "$blacklisted_markets"; then
				echo "$blacklist_market already blacklisted"
			else
				echo "$blacklist_market,$blacklist_timestamp,$blacklist_max_age" >> "$blacklisted_markets"
				echo "$blacklist_market added to blacklist"
				send_email "INFO: $blacklist_market added to blacklist" "Market: $blacklist_market \nMarket status: $trade_pair_status \nBlacklist reason: $blacklist_reason \nBlacklist expiry (hours): $blacklist_expiry_hours"
			fi
		fi
	elif [ "$blacklist_method" = "update" ]; then
		if [ ! -f "$blacklisted_markets" ]; then
			echo "$blacklisted_markets file doesn't exist - nothing to update"
			blacklist_empty="true"
		elif [ -z "$(cat "$blacklisted_markets")" ]; then
			echo "$blacklisted_markets is empty - nothing to update"
			blacklist_empty="true"
		else
			while read -r line; do
				blacklisted_market="$(echo "$line" | awk -F "," '{print $1}')"
				blacklisted_add_timestamp="$(echo "$line" | awk -F "," '{print $2}')"
				blacklisted_expiry_timestamp="$(echo "$line" | awk -F "," '{print $3}')"
				blacklisted_age="$(($blacklisted_expiry_timestamp - $blacklisted_add_timestamp / 60 / 60))"
				if [ "$(date +%s)" -lt "$blacklisted_expiry_timestamp" ]; then
					# expired markets won't be written to temp file
					echo "$line" >> "$blacklist_temp"
				else
					echo "$blacklisted_market removed from $blacklisted_markets"
					send_email "INFO: $blacklisted_market removed from blacklist" "Market: $blacklisted_market \nBlacklist age: $blacklisted_age"
				fi
			done < "$blacklisted_markets"
			# overwrite blacklist
			mv "$blacklist_temp" "$blacklisted_markets"
			if [ -z "$(cat "$blacklisted_markets")" ]; then
				echo "$blacklisted_markets is empty after updates"
				blacklist_empty="true"
			else
				blacklist_empty="false"
			fi
		fi
	elif [ "$blacklist_method" = "list" ]; then
		if [ "$blacklist_empty" = "false" ]; then
			# generate ignore list for get_markets function in the following format:
			# contains("abc") or contains("def")
			while read -r line; do
				blacklisted_market="$(echo "$line" | awk -F "," '{print $1}')"
				echo "contains(\"$blacklisted_market\")" >> "$blacklist_temp"
			done < "$blacklisted_markets"
			if [ "$(cat "$blacklist_temp" | wc -l)" -lt 2 ]; then
				blacklist_contains="$(cat "$blacklist_temp")"
			else
				blacklist_contains="$(sed ':a;N;$!ba;s/\n/ or /g' "$blacklist_temp")"
			fi
			echo "ignoring blacklisted markets ($blacklist_contains)"
		else
			blacklist_contains=""
		fi
	else
		echo "Error: Unknown or missing method ($blacklist_method) in blacklist_manager function"
		send_email "Error: Unknown method in blacklist_manager function" "Method: $blacklist_method"
		sleep 5
		return 1
	fi
}

collect_backtest_data() {
	# writes market ask and bid to a base currency specific file with timestamps
	backtest_data_file="$base_currency-backtest.data"
	backtest_data_file_header="timestamp,base_currency,market_ask,market_bid"
	backtest_data_time_epoch="$(date +"%s")"
	if [ ! -f "$backtest_data_file" ]; then
		echo "$backtest_data_file_header" > "$backtest_data_file"
	fi
	echo "$backtest_data_time_epoch,$base_currency,$market_ask,$market_bid" >> "$backtest_data_file"
}

take_profit_check() {
	# this doesn't take fees into account - fee percentage is expected to be factored into take_profit_percentage config var
	# ToDo: should probably perform the fee calc here and make the config more simple (profit after fee loss)
	take_profit_percentage_calc="$(echo "(($market_bid - $trade_history_rate) / $trade_history_rate) * 100" | bc -l | xargs printf "%.8f")"
	take_profit_percentage_compare="$(echo "$take_profit_percentage_calc >= $take_profit_percentage" | bc -l)"
	if [ "$take_profit_percentage_compare" -eq 1 ]; then
		echo "Take profit triggered - market bid up $take_profit_percentage_calc %"
		send_email "INFO: Take profit percentage triggered for $market_name" "Profit percentage: $take_profit_percentage_calc %"
		take_profit="true"
	elif [ "$take_profit_percentage_compare" -eq 0 ]; then
		take_profit="false"
	else
		echo "Error: can't compare take profit percentage"
		sleep 5
		return 1
	fi
}

trading_action(){
	# Moved from main script so this can be used in backtesting scripts as well
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
		trade_decision || return 1
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
		trade_decision || return 1
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
				trade_decision || return 1
			fi
		fi
	fi

	# Trading
	if [ "$action" = "Buy" ]; then
		if [ "$low_buy_balance" = "true" ]; then
			echo "action is $action and low_buy_balance is $low_buy_balance, so exitting current trade loop"
			echo "sleeping for 60 seconds"
			sleep 60
			return 1	# restart main while loop
		fi
		trade_type="Buy"
		get_balance "$quote_currency" || return 1
		echo "Balance: $available_balance $currency"
		currency_to_trade="$quote_currency"
		trade_calculator || return 1
		submit_trade_order || return 1
		echo "$market_name" > "$restore_market_name"
	elif [ "$action" = "Sell" ]; then
		if [ "$low_sell_balance" = "true" ]; then
			echo "action is $action and low_sell_balance is $low_sell_balance, so exitting current trade loop"
			echo "sleeping for 60 seconds"
			sleep 60
			return 1	# restart main while loop
		fi
		trade_type="Sell"
		get_balance "$base_currency" || return 1
		echo "Balance: $available_balance $currency"
		currency_to_trade="$base_currency"
		trade_calculator || return 1
		submit_trade_order || return 1
	elif [ "$action" = "Hold" ]; then
		echo "Trading thresholds not met"
		echo "Holding on until next run"
	else
		echo "Error: unknown action..."
	fi
}


#self_heal() {
	# swap action or decision if exchange allowed a dodgy trade or balance is too low on one-side
	# if low balance
		# check opposite balance
			# if greater than min trade, perform trade and remove low balance variable
#}



# push data into influxdb to build graphs and alerts
publish_to_influxdb() {
	# arg1 balance|trade
	# arg2 currency|direction
	# arg3 amount_in_btc|buy/sell

	#TODO: Also track MAs and ask/bids to visualise in grafana and not rely on exchange UI

	market_position

	base_balance_in_quote_currency="$(echo "$base_balance * $market_last_price" | bc -l | xargs printf "%.8f")"

	publish_base_balance="balance,holding=$base_currency value=$base_balance_in_quote_currency"
	publish_quote_balance="balance,holding=$quote_currency value=$quote_balance"
	publish_total_balance="balance,holding=total_holiding value=$quote_total"

	influxdb_data=("$publish_base_balance" "$publish_quote_balance" "$publish_total_balance")

	# only publish to influxdb if hostname set
		# should probably check all influxdb variables here
	if [ -n "$influxdb_host" ]; then
		echo "Publishing metrics to influxdb host ($influxdb_host)"
		for data in "${influxdb_data[@]}"; do
			# push data to InfluxDB
			curl \
			--silent \
			--request POST \
			--url "http://$influxdb_host:$influxdb_port/write?db=$influxdb_database" \
			-u "$influxdb_user:$influxdb_pass" \
			--data-binary "$data" || return 1
		done
	fi
}
