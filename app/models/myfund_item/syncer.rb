class MyfundItem::Syncer
  attr_reader :myfund_item

  def initialize(myfund_item)
    @myfund_item = myfund_item
  end

  def perform_sync(sync)
    provider = myfund_item.myfund_provider
    unless provider
      raise StandardError, "myFund.pl provider is not configured"
    end

    sync.update!(status_text: "Fetching portfolio from myFund.pl...") if sync.respond_to?(:status_text)
    data = provider.get_portfolio

    myfund_item.update!(raw_payload: data.to_json, last_synced_at: Time.current)

    sync.update!(status_text: "Processing portfolio data...") if sync.respond_to?(:status_text)

    account = find_or_create_account(data)
    sync_holdings(account, data)
    sync_historical_values(account, data)

    sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
    account.sync_later(parent_sync: sync)
  end

  def perform_post_sync
    # no-op
  end

  private

    def find_or_create_account(data)
      portfolio_data = data["portfel"] || {}
      portfolio_value = portfolio_data["wartosc"]&.to_d || 0
      currency = portfolio_data["waluta"] || "PLN"

      # Use stored account reference if available
      account = myfund_item.account

      if account.nil?
        account = Account.create_and_sync(
          {
            family: myfund_item.family,
            name: "myFund: #{myfund_item.portfolio_name}",
            balance: portfolio_value,
            currency: currency,
            accountable_type: "Investment",
            accountable_attributes: { subtype: "brokerage" }
          },
          skip_initial_sync: true
        )

        myfund_item.update!(account: account)
      else
        account.update!(balance: portfolio_value, currency: currency)
      end

      account
    end

    def sync_holdings(account, data)
      tickers_data = data["tickers"]
      return if tickers_data.blank?

      # API returns a Hash keyed by index strings ("1", "2", ...), not an Array
      ticker_entries = tickers_data.is_a?(Hash) ? tickers_data.values : Array(tickers_data)
      today = Date.current

      ticker_entries.each do |ticker_data|
        # Skip cash/account entries
        next if ticker_data["typ"] == "Accounts"

        ticker_symbol = ticker_data["tickerClear"]&.upcase
        next if ticker_symbol.blank?

        security = Security.find_or_create_by!(ticker: ticker_symbol) do |s|
          s.name = ticker_data["nazwa"]
        end

        qty = ticker_data["liczbaJednostek"]&.to_d || 0
        price = ticker_data["close"]&.to_d || 0
        amount = ticker_data["wartosc"]&.to_d || (qty * price)

        next if qty.zero?

        holding = account.holdings.find_or_initialize_by(
          security: security,
          date: today,
          currency: account.currency
        )

        holding.assign_attributes(
          qty: qty,
          price: price,
          amount: amount
        )

        holding.save!
      end
    end

    def sync_historical_values(account, data)
      values_over_time = data["wartoscWCzasie"]
      return if values_over_time.blank?

      # Get existing valuation dates to avoid duplicates
      existing_dates = account.entries.where(entryable_type: "Valuation")
                              .pluck(:date)
                              .to_set

      # API returns a Hash keyed by date strings ("2024-10-01" => "14043.03"), not an Array
      entries_to_process = if values_over_time.is_a?(Hash)
        values_over_time.map { |date_str, val| { "data" => date_str, "wartosc" => val } }
      else
        Array(values_over_time)
      end

      entries_to_process.each do |entry|
        date = parse_date(entry["data"] || entry["date"])
        next if date.nil?
        next if existing_dates.include?(date)

        value = entry["wartosc"]&.to_d || entry["value"]&.to_d
        next if value.nil?

        account.entries.create!(
          date: date,
          name: "myFund.pl portfolio value",
          amount: value,
          currency: account.currency,
          entryable: Valuation.new(kind: "reconciliation"),
          source: "myfund"
        )
      end
    end

    def parse_date(date_str)
      return nil if date_str.blank?
      Date.parse(date_str)
    rescue Date::Error
      nil
    end
end
