require "test_helper"

class LocalStatementImportTest < ActiveSupport::TestCase
  test "backfilling Nomad cannot resurrect a holding absent from a later complete snapshot" do
    investment = @family.accounts.create!(name: "Nomad", balance: 100, currency: "USD", accountable: Investment.new)
    common = { "bank_name" => "Nomad", "currency" => "USD", "local_parser_version" => 2,
      "opening_cash_balance" => "100", "closing_cash_balance" => "100", "transactions" => [] }
    october = prepare_import(investment, common.merge("period_end" => "2026-10-31", "position_date" => "2026-10-31",
      "closing_balance" => "100", "securities_balance" => "0", "positions" => []))
    october.publish
    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))
    september = prepare_import(investment, common.merge("period_end" => "2026-09-30", "position_date" => "2026-09-30",
      "closing_balance" => "500", "securities_balance" => "400", "positions" => [
        { "ticker" => "AAPL", "quantity" => "4", "price" => "100", "market_value" => "400" } ]))
    september.publish
    assert september.reload.complete?, september.error
    assert_equal 0, investment.holdings.where(date: Date.new(2026, 10, 31)).sole.qty
    assert_equal 4, investment.holdings.where(date: Date.new(2026, 9, 30)).sole.qty
  end

  test "split automatic card payments match the two account debits" do
    card = families(:empty).accounts.create!(name: "Mercado cartão", balance: 100, currency: "BRL", accountable: CreditCard.new)
    bank_data = { "bank_name" => "Mercado Pago", "currency" => "BRL", "local_parser_version" => 2,
      "transactions" => [ 60, 40 ].map { |amount| movement("bank-#{amount}").merge("date" => "2026-10-05",
        "name" => "Débito automático Fatura do cartão", "amount" => (-amount).to_s) } }
    bank_import = prepare_import(@account, bank_data)
    bank_import.publish
    invoice_data = { "bank_name" => "Mercado Pago Cartão", "currency" => "BRL", "local_parser_version" => 2,
      "document_type" => "credit_card_statement", "period_end" => "2026-10-29", "due_date" => "2026-11-04",
      "statement_closing_balance" => "20", "transactions" => [ 60, 40 ].map { |amount|
        movement("card-#{amount}").merge("date" => "2026-10-05", "name" => "Débito automático da fatura",
          "amount" => amount.to_s, "kind" => "cc_payment") } + [ movement("purchase").merge("amount" => "-20") ] }
    invoice = prepare_import(card, invoice_data)
    invoice.publish
    assert invoice.reload.complete?, invoice.error
    assert_equal 2, Transfer.where(outflow_transaction: @account.transactions).count
    assert_equal [ "cc_payment" ], @account.transactions.distinct.pluck(:kind)
    assert_equal 3, card.transactions.count
    bank_import.revert
    assert_equal 2, card.transactions.where(kind: "cc_payment").count
    bank_import.publish
    assert_equal 2, Transfer.where(outflow_transaction: @account.transactions).count
  end

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Mercado Pago", balance: 100, currency: "BRL", accountable: Depository.new)
  end

  test "publishes identical amounts as distinct operations and importing again is idempotent" do
    data = { "bank_name" => "Mercado Pago", "currency" => "BRL", "local_parser_version" => 2,
      "transactions" => [ movement("operation-a"), movement("operation-b") ] }
    first = prepare_import(@account, data)
    first.import!
    assert_equal 2, @account.transactions.count
    second = prepare_import(@account, data)
    second.import!
    assert_equal 2, @account.transactions.count
    assert_equal 0, second.rows_count
  end

  test "a reserve movement creates an internal transfer and reverts both legs" do
    data = { "bank_name" => "Mercado Pago", "currency" => "BRL", "local_parser_version" => 2,
      "transactions" => [ movement("reserve-a").merge("name" => "Reserva por gastos Emergência",
        "reserve_name" => "Emergência", "kind" => "funds_movement") ] }
    statement_import = prepare_import(@account, data)
    statement_import.import!
    reserve = @family.accounts.find_by!(name: "Mercado Pago · Reserva Emergência")
    assert_equal(-2.to_d, reserve.entries.sole.amount)
    assert_equal 2, statement_import.entries.count
    transfer = Transfer.find_by!(outflow_transaction: @account.transactions.sole)
    assert transfer.confirmed?
    statement_import.revert
    assert statement_import.reload.pending?, statement_import.error
    assert_empty @account.transactions
    assert_empty reserve.entries
  end

  test "Nomad publishes a closing valuation and preserves its original USD currency" do
    investment = @family.accounts.create!(name: "Nomad", balance: 400, currency: "USD", accountable: Investment.new)
    data = { "bank_name" => "Nomad", "currency" => "USD", "local_parser_version" => 2,
      "period_end" => "2026-10-31", "position_date" => "2026-10-31", "closing_balance" => "500.00",
      "positions" => [ { "ticker" => "AAPL", "quantity" => "4", "price" => "100", "market_value" => "400" } ],
      "transactions" => [ movement("deposit").merge("amount" => "100", "currency" => "USD") ] }
    Security::Resolver.any_instance.stubs(:resolve).returns(securities(:aapl))
    statement_import = prepare_import(investment, data)
    statement_import.import!
    assert_equal 500.to_d, investment.entries.valuations.sole.amount
    assert_equal "USD", investment.entries.valuations.sole.currency
    assert_equal 400.to_d, investment.holdings.sole.amount
    assert_equal statement_import.id, investment.entries.valuations.sole.import_id
    statement_import.revert
    investment.reload
    assert_empty investment.holdings
    assert_empty investment.entries
  end

  test "local-only imports reject an unknown document without invoking an AI provider" do
    statement_import = PdfImport.create!(family: @family, column_mappings: { "local_only" => true })
    statement_import.stubs(:pdf_file_content).returns("unknown")
    LocalStatementParser.stubs(:parse).returns(nil)
    Provider::Registry.expects(:preferred_llm_provider).never
    assert_raises(LocalStatementParser::UnsupportedStatementError) { statement_import.process_with_ai }
  end

  test "card payments are linked when the bank statement arrives first" do
    check_card_payment_order(bank_first: true)
  end

  test "card payments are linked when the invoice arrives first" do
    check_card_payment_order(bank_first: false)
  end

  test "an empty Nomad portfolio closes the previous positions and remains reversible" do
    investment = @family.accounts.create!(name: "Nomad", balance: 400, currency: "USD", accountable: Investment.new)
    prior = investment.holdings.create!(security: securities(:aapl), date: Date.new(2026, 9, 30),
      qty: 4, price: 100, amount: 400, currency: "USD", external_id: "nomad-statement-prior-AAPL")
    statement_import = prepare_import(investment, { "bank_name" => "Nomad", "currency" => "USD", "local_parser_version" => 2,
      "period_end" => "2026-10-31", "position_date" => "2026-10-31", "closing_balance" => "100",
      "opening_cash_balance" => "100", "closing_cash_balance" => "100", "securities_balance" => "0",
      "positions" => [], "transactions" => [] })
    statement_import.import!
    assert_equal 0, investment.holdings.where(date: Date.new(2026, 10, 31)).sole.qty
    assert investment.holdings.exists?(prior.id)
    statement_import.revert
    assert statement_import.reload.pending?, statement_import.error
    assert_equal [ prior.id ], investment.holdings.pluck(:id)
  end

  private
    def check_card_payment_order(bank_first:)
      card = @family.accounts.create!(name: "Santander cartão", balance: 0, currency: "BRL", accountable: CreditCard.new)
      bank = prepare_import(@account, { "bank_name" => "Santander", "currency" => "BRL", "local_parser_version" => 2,
        "transactions" => [ movement("bank-payment").merge("date" => "2026-09-30", "name" => "PAGAMENTO CARTAO CREDITO",
          "amount" => "-100", "kind" => "cc_payment") ] })
      invoice = prepare_import(card, { "bank_name" => "Santander Cartão", "currency" => "BRL", "local_parser_version" => 2,
        "document_type" => "credit_card_statement", "period_end" => "2026-09-24", "due_date" => "2026-10-01",
        "statement_closing_balance" => "100", "transactions" => [ movement("card-purchase").merge("amount" => "-100") ] })
      (bank_first ? [ bank, invoice ] : [ invoice, bank ]).each(&:publish)
      assert bank.reload.complete?, bank.error
      assert invoice.reload.complete?, invoice.error
      assert_equal 1, Transfer.where(outflow_transaction: @account.transactions).count
      assert_equal 2, card.transactions.count
      assert_equal 1, bank.entries.where(account: card).count, "counterpart belongs to the bank import so its reversal removes both legs"
      bank.revert
      assert_equal 1, card.transactions.count
      assert_empty @account.transactions
    end

    def movement(reference)
      { "date" => "2026-10-01", "name" => "Compra", "amount" => "-2", "external_id" => reference }
    end

    def prepare_import(account, data)
      statement_import = PdfImport.create!(family: @family, account: account, extracted_data: data,
        ai_summary: "Local", document_type: "bank_statement", date_format: "%Y-%m-%d")
      statement_import.generate_rows_from_extracted_data
      statement_import.sync_mappings
      statement_import
    end
end
