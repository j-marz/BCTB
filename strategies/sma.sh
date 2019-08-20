#!/bin/bash

# Simple Moving Average (SMA)
	# compare current price with the moving average
	# if the price crosses below the average, then sell
	# if the price crosses above the average, then buy

# Average = (trade 1 + trade 2 + trade 3 + ... ) / number of trades

# Check last trade rate + trade fee to avoid selling for less that previous buy regardless of signal

trade_decision() {
	if [ "$ma_data_source" = "trades" ]; then
		get_market_history || return 1
		sma_average="$(echo "$market_history_prices" | head -n "$sma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	elif [ "$ma_data_source" = "candles" ]; then
		get_candles || return 1
		sma_average="$(echo "$candles_close_list" | tail -n "$sma_period" | jq -r -s 'add/length' | xargs printf "%.8f")"
	else
		echo "ERROR: Unknown SMA data source ($ma_data_source)"
		send_email "ERROR: Unknown SMA data source ($ma_data_source)"
		return 1
	fi
	echo "Last trade rate: $trade_history_rate $quote_currency"
	echo "Market history average price: $sma_average (source: $ma_data_source)"
	if [ "$ma_data_source" = "trades" ]; then
		echo "Market history trade count: $market_history_trade_count"
	elif [ "$ma_data_source" = "candles" ]; then
		echo "Market candle interval ($candles_interval) and SMA period ($sma_period)"
	fi
	if [ "$trade_history_type" = "Buy" ]; then
		# if last trade was buy, use the sell price (market_bid)
		bull_market_compare="$(echo "$market_bid > $sma_average" | bc -l)"
		# must be greater than previous trade rate + previous trade fee + current trade fee
		#bull_trade_compare="$(echo "$market_bid > (($trade_history_rate * ($trade_fee / 100)) + $trade_history_rate)" | bc -l)"
		###### maybe should change to >= so some bad positions can exit without loss and bot can continue, instead of waiting days for a return?
			# might also cause some trades to end early and not make profit?
		bull_trade_compare="$(echo "$market_bid > (($trade_history_rate * ($trade_fee / 100)) + $trade_history_rate + ($market_bid * ($trade_fee / 100)))" | bc -l)"
		if [ "$bull_market_compare" -eq 1 ]; then
			echo "Bull: Market bid ($market_bid) > Market history ($ma_data_source) average ($sma_average)"
			if [ "$bull_trade_compare" -eq 1 ]; then	# In case SMA signal alone causes a loss
				echo "Bull: Market bid ($market_bid) > Last $trade_history_type trade ($trade_history_rate)"
				echo "SELL!"
				trade_rate="$market_bid"
				action="Sell"
			else
				echo "Trade would result in a loss using SMA signal alone"
				echo "HOLD!"
				action="Hold"
			fi
		else
			echo "No SMA cross-overs detected"
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
	elif [ "$trade_history_type" = "Sell" ]; then
		# if last trade was sell, use the buy price (market_ask)
		bear_market_compare="$(echo "$market_ask < $sma_average" | bc -l)"
		#bear_trade_compare="$(echo "$market_ask < (($trade_history_rate * ($trade_fee / 100)) + $trade_history_rate)" | bc -l)"
		###### maybe we should check if ask is lower than last sell trade rate?
		if [ "$bear_market_compare" -eq 1 ]; then
			echo "Bear: Market ask ($market_ask) < Market history ($ma_data_source) average ($sma_average)"
			#if [ "$bear_trade_compare" -eq 1 ]; then	# In case SMA signal alone causes a loss
				#echo "Bear: Market ask ($market_ask) < Last $trade_history_type trade ($trade_history_rate)"
				echo "BUY!"
				trade_rate="$market_ask"
				action="Buy"
			#else
				#echo "Trade would result in a loss using SMA signal alone"
				#echo "HOLD!"
				#action="Hold"
			#fi
		else
			echo "No SMA cross-overs detected"
			echo "HOLD!"
			action="Hold"	
		fi
	else
		echo "Error: Unknown trade history type of $trade_history_type detected in trade_decision function"
		return 1
	fi
}