require "test_helper"

class LocalStatementParserTest < ActiveSupport::TestCase
  test "Mercado Pago automatic bill debits are payments, not new purchases" do
    cover = "Emitida em: 30/10/2026\nConsumos de 30/09 a 29/10\nTotal da fatura de setembro R$ 100,00\nTotal R$ 20,00"
    details = "05/10 Débito automático da fatura de outubro/2026 R$ 100,00\n10/10 Compra R$ 20,00"
    data = LocalStatementParser::MercadoPagoCard.new([ cover, details ]).parse
    assert_equal 100.to_d, data[:transactions].first[:amount]
    assert_equal "cc_payment", data[:transactions].first[:kind]
    assert_equal data, LocalStatementParser.validate!(data)
  end

  test "Santander card reads transactions alongside a summary in another column" do
    cover = "TotalaPagar Vencimento\nR$120,00 01/11/2026\naté26/10."
    details = <<~TEXT
                                                         Resumo da Fatura
      30/09 PAGAMENTODEFATURA-INTERNET  -100,00             SaldoAnterior 100,00
      26/10 DESCONTODOMES                -5,00             (=)SaldoDestaFatura 120,00
      05/10 LOJA                       120,00
            IOFDESPESANOEXTERIOR         5,00
    TEXT
    data = LocalStatementParser::SantanderCard.new([ cover, details ]).parse
    assert_equal 4, data[:transactions].size
    assert_equal [ 100.to_d, 5.to_d, -120.to_d, -5.to_d ], data[:transactions].pluck(:amount)
    assert_equal data, LocalStatementParser.validate!(data)
  end

  test "Santander reads October across pages and verifies reported balances" do
    cover = "EXTRATO CONSOLIDADO INTELIGENTE outubro/2027"
    first = <<~TEXT
      Conta Corrente Movimentação
      SALDO EM 30/09 100,00
      01/10 PIX ENVIADO TESTE - 10,00- 90,00
    TEXT
    last = <<~TEXT
      Conta Corrente Data Descrição Movimento (R$) Saldo (R$)
      31/10 LIQUIDO DE VENCIMENTO 010930 200,00 290,00
      SALDO EM 31/10 290,00
    TEXT
    result = LocalStatementParser::Santander.new([ cover, first, last ]).parse
    assert_equal %w[2027-10-01 2027-10-31], result[:transactions].pluck(:date)
    assert_equal 100.to_d, result[:opening_balance]
    assert_equal 290.to_d, result[:closing_balance]
    assert_equal "2027-10-31", result[:period_end]
  end

  test "statement validation refuses a missing movement instead of silently publishing" do
    data = { bank_name: "Mercado Pago", currency: "BRL", opening_balance: 100.to_d,
      closing_balance: 200.to_d, transactions: [ { date: "2027-10-01", name: "Deposit", amount: 90.to_d } ] }
    assert_raises(LocalStatementParser::InvalidStatementError) { LocalStatementParser.validate!(data) }
  end

  test "XP uses period ledger closing cash rather than the current balance in the header" do
    text = <<~TEXT
      XPINVESTIMENTOS Extratodaconta
      De: 01/09/2026Até: 30/09/2026
      Saldodisponível: R$688,81
      Liq Mov Histórico Valor Saldo
      21/09/2026 21/09/2026 TED RETIRADAEM C/C -R$150,00 R$0,00
      15/09/2026 15/09/2026 RENDIMENTOS DE CLIENTES VISC11 100 R$10,00 R$150,00
      03/09/2026 01/09/2026 OPERAÇÕES EM BOLSA -R$20,00 R$140,00
      Lançamentosfuturos
    TEXT
    result = LocalStatementParser::Xp.new([ text ]).parse
    assert_equal 160.to_d, result[:opening_balance]
    assert_equal 0.to_d, result[:closing_balance]
    assert_equal "2026-09-03", result[:transactions].first[:date]
    assert_equal "BRL", result[:currency]
    assert_equal result, LocalStatementParser.validate!(result)
  end

  test "XP refuses an unreadable boundary transaction rather than deriving a partial balance" do
    text = <<~TEXT
      De: 01/10/2026Até: 31/10/2026
      21/10/2026 21/10/2026 RETIRADA valor ilegível R$0,00
      15/10/2026 15/10/2026 RENDIMENTOS R$10,00 R$150,00
    TEXT
    assert_raises(LocalStatementParser::InvalidStatementError) { LocalStatementParser::Xp.new([ text ]).parse }
  end

  test "Mercado Pago card reads every detail page and keeps a refund as credit" do
    cover = "Emitida em: 31/01/2027\nConsumos de 30/12 a 29/01\nTotal R$ 15,00"
    pages = [ cover, "30/12 Loja A R$ 10,00", "", "", "05/01 Estorno Loja A R$ 5,00\n06/01 Loja B R$ 10,00" ]
    result = LocalStatementParser::MercadoPagoCard.new(pages).parse
    assert_equal 3, result[:transactions].size
    assert_equal %w[2026-12-30 2027-01-05 2027-01-06], result[:transactions].pluck(:date)
    assert_equal [ -10.to_d, 5.to_d, -10.to_d ], result[:transactions].pluck(:amount)
  end

  test "Santander card handles installments billed in January with a December purchase" do
    cover = "TotalaPagar Vencimento\nR$10,00 01/02/2027\naté24/01."
    result = LocalStatementParser::SantanderCard.new([ cover, "24/12 LOJA 02/03 10,00" ]).parse
    assert_equal "2027-01-24", result[:transactions].sole[:date]
    assert_match "24/12/2026", result[:transactions].sole[:notes]
  end

  test "Mercado Pago preserves signed values and internal transfer hints" do
    page = <<~TEXT
      EXTRATO DE CONTA
      Periodo: De 01-09-2026 al 30-09-2026
      Saldo inicial: R$ 100,00 Saldo final: R$ 113,00
      01-09-2026 Rendimentos 1234567890123 R$ 5,00 R$ 105,00
      01-09-2026 Reserva por gastos Emergência 1234567890124 R$ -2,00 R$ 103,00
      30-09-2026 MELI DEVELOPERS BRASIL LTDA 1234567890125 R$ 10,00 R$ 113,00
    TEXT
    result = LocalStatementParser::MercadoPago.new([ page ]).parse

    assert_equal [ 5.0, -2.0, 10.0 ], result[:transactions].pluck(:amount)
    assert_equal 113.0, result[:closing_balance]
    assert_match(/transferência interna/, result[:transactions][1][:notes])
    assert_equal "Salário", result[:transactions].last[:category]
  end

  test "Santander distinguishes debits and credits without duplicating balances" do
    page = <<~TEXT
      EXTRATO CONSOLIDADO INTELIGENTE setembro/2026
      Conta Corrente
      Movimentação
      08/09 PIX ENVIADO TESTE - 11,96- 88,04
      30/09 LIQUIDO DE VENCIMENTO 010930 100,00 188,04
      SALDO EM 30/09 188,04
    TEXT
    result = LocalStatementParser::Santander.new([ page ]).parse

    assert_equal [ -11.96, 100.0 ], result[:transactions].pluck(:amount)
    assert_equal %w[2026-09-08 2026-09-30], result[:transactions].pluck(:date)
  end

  test "Nomad keeps sweeps out of cash flow and parses positions" do
    activities = <<~TEXT
      Statement Date: 2026-09-01 - 2026-09-30
      2026-09-10 DEPOSIT ICT Deposit 0.00 692.42 0.00
      2026-09-11 SWEEP FDIC Sweep 0.00 692.42 0.00
      2026-09-22 CASH_DIVIDEND TEST ETF TRUST VOO 0.00 10.00 0.00
      With 30% NON Resident Alien Withholding Deductions
    TEXT
    portfolio = <<~TEXT
      PORTFOLIO Market Value
      TEST ETF TRUST VOO 2.00000 0 100.00 200.00 190.00
    TEXT
    result = LocalStatementParser::Nomad.new([ activities, portfolio ]).parse

    assert_equal [ 692.42.to_d, 10.to_d, -3.to_d ], result[:transactions].pluck(:amount)
    assert_equal "USD", result[:currency]
    assert_equal "VOO", result[:positions].first[:ticker]
    assert_equal 200.to_d, result[:positions].first[:market_value]
  end

  test "Nomad reads cash, purchases and closing value for another month" do
    page = <<~TEXT
      Statement Date: 2027-10-01 - 2027-10-31
      Cash Balance 0.00 0.00
      FDIC Insured Deposits 100.00 80.00
      Securities Valuation 200.00 225.00
      Total Net Worth 300.00 305.00
      2027-10-10 BUY TEST ETF VOO 0.00 -20.00 0.00
      PORTFOLIO Market Value
      TEST ETF VOO 2.00000 0 112.50 225.00 200.00
    TEXT
    result = LocalStatementParser::Nomad.new([ page ]).parse
    assert_equal 305.to_d, result[:closing_balance]
    assert_equal 80.to_d, result[:closing_cash_balance]
    assert_equal "funds_movement", result[:transactions].sole[:kind]
    assert_equal result, LocalStatementParser.validate!(result)
  end

  test "Mercado Pago card treats statement credit separately from billed purchases" do
    page = <<~TEXT
      30/08 Crédito concedido R$ 6.024,00
      04/09 PG *TEMBICI R$ 7,90
      27/08 AMAZON MKT Parcela 2 de 12 R$ 502,00
    TEXT
    cover = "Emitida em: 30/09/2026\nConsumos de 30/08 a 29/09\nTotal R$ 2.598,65"
    result = LocalStatementParser::MercadoPagoCard.new([ cover, page ]).parse

    assert_equal [ 6024.to_d, -7.9.to_d, -502.to_d ], result[:transactions].pluck(:amount)
    assert_equal %w[2026-08-30 2026-09-04 2026-09-29], result[:transactions].pluck(:date)
    assert_equal "credit_card_statement", result[:document_type]
    assert_equal 2598.65.to_d, result[:statement_closing_balance]
  end

  test "Santander card separates payment, discount, charges and foreign tax" do
    cover = "TotalaPagar Vencimento\nR$1.595,73 01/10/2026\naté24/09."
    details = <<~TEXT
      26/08 PAGAMENTODEFATURA -1.145,73
      24/09 DESCONTODOMES -18,93
      08/07 AIRBNB * HMF9JC5 03/06 462,34
      12/09 BASSBUZZCOM 1.078,10 197,00
      IOF DESPESA NO EXTERIOR 37,73
    TEXT
    result = LocalStatementParser::SantanderCard.new([ cover, details ]).parse

    assert_equal 5, result[:transactions].size
    assert_equal [ 1145.73.to_d, 18.93.to_d, -462.34.to_d, -1078.10.to_d, -37.73.to_d ],
      result[:transactions].pluck(:amount)
    assert_equal "2026-09-24", result[:transactions][2][:date]
    assert_equal 1595.73.to_d, result[:statement_closing_balance]
  end
end
