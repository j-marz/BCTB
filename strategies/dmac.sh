#!/bin/bash

# Dual Moving Average Crossover (DMAC)
	# Two moving averages - short and long
	# Buy when price is >= short and < long
	# Sell when price <= short and > long

# Average = (trade 1 + trade 2 + trade 3 + ... ) / number of trades
	# Short team moving average (STMA)
	# Long term moving average (LTMA)

# Check last trade rate + trade fee to avoid selling for less that previous buy regardless of signal

trade_decision() {
	if [ "$ma_data_source" = "trades" ]; then
		get_market_history || return 1
		stma_average="$(echo "$market_history_prices" | head -n "$stma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
		ltma_average="$(echo "$market_history_prices" | head -n "$ltma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	elif [ "$ma_data_source" = "candles" ]; then
		get_candles || return 1
		stma_average="$(echo "$candles_close_list" | tail -n "$stma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
		ltma_average="$(echo "$candles_close_list" | tail -n "$ltma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	else
		echo "ERROR: Unknown DMAC data source ($ma_data_source)"
		send_email "ERROR: Unknown DMAC data source ($ma_data_source)"
		return 1
	fi
	echo "Last trade rate: $trade_history_rate $quote_currency"
	echo "Market history STMA price: $stma_average (source: $ma_data_source)"
	echo "Market history LTMA price: $ltma_average (source: $ma_data_source)"
	if [ "$ma_data_source" = "trades" ]; then
		echo "Market history trade count: $market_history_trade_count"
	elif [ "$ma_data_source" = "candles" ]; then
		echo "Market candle interval ($candles_interval), STMA period ($stma_period) and LTMA period ($ltma_period)"
	fi
	if [ "$trade_history_type" = "Buy" ]; then	# if last trade was buy, use the sell price (market_bid)
		compare_bid_stma="$(echo "$market_bid <= $stma_average" | bc -l)"
		compare_bid_ltma="$(echo "$market_bid > $ltma_average" | bc -l)"
		if [ "$compare_bid_stma" -eq 1 ] && [ "$compare_bid_ltma" -eq 1 ]; then
			echo "Sell Signal: Market bid ($market_bid) <= Market history ($ma_data_source) STMA ($stma_average) and > LTMA ($ltma_average)"
			dmac_profit_check="$(echo "$market_bid > (($trade_history_rate * ($trade_fee / 100)) + $trade_history_rate + ($market_bid * ($trade_fee / 100)))" | bc -l)"
			if [ "$dmac_profit_check" -eq 1 ]; then	# In case MA signal alone causes a loss
				echo "Profit check: Market bid ($market_bid) > Last $trade_history_type trade ($trade_history_rate)"
				echo "SELL!"
				trade_rate="$market_bid"
				action="Sell"
			else
				echo "Trade would result in a loss using DMAC signal alone"
				echo "HOLD!"
				action="Hold"
			fi
		else
			echo "No DMAC cross-overs detected"
			echo "HOLD!"
			action="Hold"
		fi
		# Override hold action if position expires or stop loss sell enforced
		if [ "$action" = "Hold" ]; then
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
		compare_ask_stma="$(echo "$market_ask >= $stma_average" | bc -l)"
		compare_ask_ltma="$(echo "$market_ask < $ltma_average" | bc -l)"
		if [ "$compare_ask_stma" -eq 1 ] && [ "$compare_ask_ltma" -eq 1 ]; then
			echo "Buy Signal: Market ask ($market_ask) >= Market history ($ma_data_source) STMA ($stma_average) and < LTMA ($ltma_average)"
			echo "BUY!"
			trade_rate="$market_ask"
			action="Buy"
		else
			echo "No DMAC cross-overs detected"
			echo "HOLD!"
			action="Hold"	
		fi
	else
		echo "Error: Unknown trade history type of $trade_history_type detected in trade_decision function"
		return 1
	fi
}