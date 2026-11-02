require "test_helper"

class LocalStatementParserTest < ActiveSupport::TestCase
  test "Mercado Pago preserves signed values and internal transfer hints" do
    page = <<~TEXT
      EXTRATO DE CONTA
      Periodo: De 01-09-2026 al 30-09-2026
      Saldo inicial: R$ 100,00 Saldo final: R$ 113,00
      01-09-2026 Rendimentos 1234567890123 R$ 5,00 R$ 105,00
      01-09-2026 Reserva por gastos Emergência 1234567890124 R$ -2,00 R$ 103,00
      30-09-2026 MELI DEVELOPERS BRASIL LTDA 1234567890125 R$ 10,00 R$ 113,00
    TEXT
    result = LocalStatementParser::MercadoPago.new([page]).parse

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
    result = LocalStatementParser::Santander.new([page]).parse

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
    result = LocalStatementParser::Nomad.new([activities, portfolio]).parse

    assert_equal [ 692.42.to_d, 10.to_d, -3.to_d ], result[:transactions].pluck(:amount)
    assert_equal "USD", result[:currency]
    assert_equal "VOO", result[:positions].first[:ticker]
    assert_equal 200.to_d, result[:positions].first[:market_value]
  end

  test "Mercado Pago card treats statement credit separately from billed purchases" do
    page = <<~TEXT
      30/08 Crédito concedido R$ 6.024,00
      04/09 PG *TEMBICI R$ 7,90
      27/08 AMAZON MKT Parcela 2 de 12 R$ 502,00
    TEXT
    cover = "Emitida em: 30/09/2026\nConsumos de 30/08 a 29/09\nTotal R$ 2.598,65"
    result = LocalStatementParser::MercadoPagoCard.new([cover, page]).parse

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
    result = LocalStatementParser::SantanderCard.new([cover, details]).parse

    assert_equal 5, result[:transactions].size
    assert_equal [ 1145.73.to_d, 18.93.to_d, -462.34.to_d, -1078.10.to_d, -37.73.to_d ],
      result[:transactions].pluck(:amount)
    assert_equal "2026-09-24", result[:transactions][2][:date]
    assert_equal 1595.73.to_d, result[:statement_closing_balance]
  end
end
