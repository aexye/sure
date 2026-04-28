require "test_helper"

class Provider::EnableBankingTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::EnableBanking.new(
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.generate(2048).to_pem
    )
    @provider.stubs(:generate_jwt).returns("test_jwt")
  end

  test "retries transaction fetch without date range when ASPSP does not support date criteria" do
    account_id = "account/with/slashes"
    url = "https://api.enablebanking.com/accounts/#{CGI.escape(account_id)}/transactions"
    error_body = {
      responseHeader: {
        requestId: "7fd838f6-430b-11f1-9aca-42004e494300",
        sendDate: "2026-04-28T14:06:49.613Z",
        isCallback: false
      },
      code: "422 UNPROCESSABLE_ENTITY",
      message: "Unsupported query criteria transactionDateFrom. See API documentation for more details"
    }.to_json

    stub_request(:get, url)
      .with(query: { date_from: "2026-04-01", transaction_status: "BOOK", continuation_key: "next_page", strategy: "longest" })
      .to_return(status: 422, body: error_body, headers: { "Content-Type" => "application/json" })

    stub_request(:get, url)
      .with(query: { transaction_status: "BOOK", continuation_key: "next_page", strategy: "longest" })
      .to_return(
        status: 200,
        body: { transactions: [ { entry_reference: "tx_1" } ], continuation_key: nil }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @provider.get_account_transactions(
      account_id: account_id,
      date_from: Date.new(2026, 4, 1),
      continuation_key: "next_page",
      transaction_status: "BOOK"
    )

    assert_equal [ { entry_reference: "tx_1" } ], result[:transactions]
  end

  test "retries transaction fetch without date range when ASPSP returns a generic bank error" do
    account_id = "pko-account"
    url = "https://api.enablebanking.com/accounts/#{CGI.escape(account_id)}/transactions"
    error_body = {
      code: "ASPSP_ERROR",
      message: "ASPSP returned an error"
    }.to_json

    stub_request(:get, url)
      .with(query: { date_from: "2026-04-01", transaction_status: "BOOK", strategy: "longest" })
      .to_return(status: 400, body: error_body, headers: { "Content-Type" => "application/json" })

    stub_request(:get, url)
      .with(query: { transaction_status: "BOOK", strategy: "longest" })
      .to_return(
        status: 200,
        body: { transactions: [ { entry_reference: "pko_tx_1" } ], continuation_key: nil }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @provider.get_account_transactions(
      account_id: account_id,
      date_from: Date.new(2026, 4, 1),
      transaction_status: "BOOK"
    )

    assert_equal [ { entry_reference: "pko_tx_1" } ], result[:transactions]
  end
end
