# BCTB
Bash Cryptocurrency Trading Bot

Written entirely in Bash, leveraging common linux tools (curl jq bc tr)

## Exchanges
* Cryptopia
* Bittrex

## Strategies
* SMA (Simple Moving Average)
* DMAC (Double Moving Average Crossover)
* Percentage (up/down)

## Dependencies
* cURL
* jq
* bc
* tr

If missing, run `sudo apt-get install curl jq bc tr` to install on Debian based distros

## Configuration
Populate Exchange API keys, notification email address and trading config in `bctb.cfg`

## Run
`./bctb.sh`