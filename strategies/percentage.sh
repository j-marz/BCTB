#!/bin/bash

# Percentage up/down strategy
# Requires profit_percentage variable to be set in config


trade_decision() {
	# adjust profit percentage to account for upward or downward trends
	if [ "$trend_percentage_increase" = "Buy" ]; then
		bull_percentage="$profit_percentage"
		bear_percentage="$(echo "$profit_percentage * -$buy_count * $buy_count" | bc -l | xargs printf "%.8f")"	# must be negative # multiply by number of consecutive trades of same type (twice to combat spikes)
	elif [ "$trend_percentage_increase" = "Sell" ]; then
		bull_percentage="$(echo "$profit_percentage * $sell_count * $sell_count" | bc -l | xargs printf "%.8f")"	# multiply by number of consecutive trades of same type (twice to combat spikes)
		bear_percentage="-$profit_percentage"	# must be negative
	else
		bull_percentage="$profit_percentage"
		bear_percentage="-$profit_percentage"	# must be negative
	fi
	# adjust profit percentages based on trading fees
	bull_fee_percentage="$(echo "($trade_fee / 100) + $bull_percentage" | bc -l | xargs printf "%.8f")"
	bear_fee_percentage="$(echo "($trade_fee / -100) + $bear_percentage" | bc -l | xargs printf "%.8f")"
	#compare previous trade rate with current market rates to work out +- percentage
	sell_trade_comparison="$(echo "(($market_bid - $trade_history_rate) / $trade_history_rate) * 100" | bc -l | xargs printf "%.8f")"
	buy_trade_comparison="$(echo "(($market_ask - $trade_history_rate) / $trade_history_rate) * 100" | bc -l | xargs printf "%.8f")"
	bull_compare="$(echo "$sell_trade_comparison >= $bull_fee_percentage" | bc -l)"
	bear_compare="$(echo "$buy_trade_comparison <= $bear_fee_percentage" | bc -l)"
	echo "Last trade rate: $trade_history_rate $quote_currency"
	echo "Sell (bid) trade comparison: $sell_trade_comparison percent"
	echo "Buy (ask) trade comparison: $buy_trade_comparison percent"
	if [ "$bull_compare" -eq 1 ]; then
		echo ">= Bull: $bull_fee_percentage percent"
		echo "SELL!"
		trade_rate="$market_bid"
		action="Sell"
	elif [ "$bear_compare" -eq 1 ]; then
		echo "<= Bear: $bear_fee_percentage percent"
		echo "BUY!"
		trade_rate="$market_ask"
		action="Buy"
	else
		echo "Trade percentage not met"
		echo ">= Bull: $bull_fee_percentage percent"
		echo "<= Bear: $bear_fee_percentage percent"
		echo "HOLD!"
		action="Hold"
	fi
	# Override hold action if position expires
	if [ "$action" = "Hold" ]; then
		if [ "$trade_history_type" = "Buy" ]; then	# must be open position
			trade_position_age || return 1
			if [ "$trade_position_expired" = "true" ]; then
				echo "SELL!"
				trade_rate="$market_bid"
				action="Sell"
			fi
		fi
	fi
	trend_percentage_increase=""	# clear variable
}