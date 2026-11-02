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
    TEXT
    portfolio = <<~TEXT
      PORTFOLIO Market Value
      TEST ETF TRUST VOO 2.00000 0 100.00 200.00 190.00
    TEXT
    result = LocalStatementParser::Nomad.new([activities, portfolio]).parse

    assert_equal 1, result[:transactions].size
    assert_equal "USD", result[:currency]
    assert_equal "VOO", result[:positions].first[:ticker]
    assert_equal 200.to_d, result[:positions].first[:market_value]
  end
end
