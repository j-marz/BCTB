#!/bin/bash

# Triple Moving Average Crossover (TMAC)
	# Three moving averages - short, medium and long
	# when stma crosses below mtma, and are both above ltma, sell signal - also set bear market when st and mt above lt
	# when stma crosses above mtma and are both below ltma, buy signal - also set bull market when st and mt above lt


# Average = (trade 1 + trade 2 + trade 3 + ... ) / number of trades
	# Short team moving average (STMA)
	# Medium team moving average (MTMA)
	# Long term moving average (LTMA)

# Check last trade rate + trade fee to avoid selling for less that previous buy regardless of signal

trade_decision() {
	if [ "$ma_data_source" = "trades" ]; then
		get_market_history || return 1
		stma_average="$(echo "$market_history_prices" | head -n "$stma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
		mtma_average="$(echo "$market_history_prices" | head -n "$mtma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
		ltma_average="$(echo "$market_history_prices" | head -n "$ltma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	elif [ "$ma_data_source" = "candles" ]; then
		get_candles || return 1
		stma_average="$(echo "$candles_close_list" | "$candles_filter" -n "$stma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
		mtma_average="$(echo "$candles_close_list" | "$candles_filter" -n "$mtma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
		ltma_average="$(echo "$candles_close_list" | "$candles_filter" -n "$ltma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	else
		echo "ERROR: Unknown TMAC data source ($ma_data_source)"
		send_email "ERROR: Unknown TMAC data source ($ma_data_source)"
		return 1
	fi
	echo "Last trade rate: $trade_history_rate $quote_currency"
	echo "Market history STMA price: $stma_average (source: $ma_data_source)"
	echo "Market history MTMA price: $mtma_average (source: $ma_data_source)"
	echo "Market history LTMA price: $ltma_average (source: $ma_data_source)"
	if [ "$ma_data_source" = "trades" ]; then
		echo "Market history trade count: $market_history_trade_count"
	elif [ "$ma_data_source" = "candles" ]; then
		echo "Market candle interval ($candles_interval), STMA period ($stma_period), MTMA period ($mtma_period) and LTMA period ($ltma_period)"
	fi
	if [ "$trade_history_type" = "Buy" ]; then	# if last trade was buy, use the sell price (market_bid)
		compare_stma_mtma="$(echo "$stma_average < $mtma_average" | bc -l)"
		compare_stma_ltma="$(echo "$stma_average > $ltma_average" | bc -l)"
		compare_mtma_ltma="$(echo "$mtma_average > $ltma_average" | bc -l)"
		if [ "$compare_stma_ltma" -eq 1 ] && [ "$compare_mtma_ltma" -eq 1 ]; then
			market_flow="bull"
		else
			market_flow="sideways"
		fi
		if [ "$compare_stma_mtma" -eq 1 ] && [ "$compare_stma_ltma" -eq 1 ] && [ "$compare_mtma_ltma" -eq 1 ]; then
			market_flow="from_bull_to_bear"
			echo "Sell Signal: SMTA ($stma_average) < MTMA ($mtma_average) and both are > LTMA ($ltma_average) using market history ($ma_data_source)"
			if [ "$risky_mode" = "true" ]; then
				echo "Risky mode ($risky_mode) - proceeding to sell without profit check"
				echo "SELL!"
				trade_rate="$market_bid"
				action="Sell"
			else
				tmac_profit_check="$(echo "$market_bid > (($trade_history_rate * ($trade_fee / 100)) + $trade_history_rate + ($market_bid * ($trade_fee / 100)))" | bc -l)"
				if [ "$tmac_profit_check" -eq 1 ]; then	# In case MA signal alone causes a loss
					echo "Profit check: Market bid ($market_bid) > Last $trade_history_type trade ($trade_history_rate)"
					echo "SELL!"
					trade_rate="$market_bid"
					action="Sell"
				else
					echo "Trade would result in a loss using TMAC signal alone"
					echo "HOLD!"
					action="Hold"
				fi
			fi
		else
			echo "No TMAC cross-overs detected"
			echo "HOLD!"
			action="Hold"
		fi
		# Override hold action if position expires, take profit or stop loss sell triggered
		if [ "$action" = "Hold" ]; then
			take_profit_check || return 1
			if [ "$take_profit" = "true" ]; then
				echo "SELL!"
				trade_rate="$market_bid"
				action="Sell"
			fi
			trade_position_age || return 1
			if [ "$trade_position_expired" = "true" ]; then
				echo "SELL!"
				trade_rate="$market_bid"
				action="Sell"
			fi
			stop_loss || return 1
			if [ "$stop_loss_sell" = "true" ]; then
				echo "SELL!"
				trade_rate="$market_bid"
				action="Sell"
			fi
		fi
	elif [ "$trade_history_type" = "Sell" ]; then	# if last trade was sell, use the buy price (market_ask)
		compare_stma_mtma="$(echo "$stma_average > $mtma_average" | bc -l)"
		compare_stma_ltma="$(echo "$stma_average < $ltma_average" | bc -l)"
		compare_mtma_ltma="$(echo "$mtma_average < $ltma_average" | bc -l)"
		if [ "$compare_stma_ltma" -eq 1 ] && [ "$compare_mtma_ltma" -eq 1 ]; then
			market_flow="bear"
		else
			market_flow="sideways"
		fi
		if [ "$compare_stma_mtma" -eq 1 ] && [ "$compare_stma_ltma" -eq 1 ] && [ "$compare_mtma_ltma" -eq 1 ]; then
			market_flow="from_bear_to_bull"
			echo "Buy Signal: SMTA ($stma_average) > MTMA ($mtma_average) and both are < LTMA ($ltma_average) using market history ($ma_data_source)"
			echo "BUY!"
			trade_rate="$market_ask"
			action="Buy"
		else
			echo "No TMAC cross-overs detected"
			echo "HOLD!"
			action="Hold"	
		fi
	else
		echo "Error: Unknown trade history type of $trade_history_type detected in trade_decision function"
		return 1
	fi

	echo "Market flow: $market_flow"
}
