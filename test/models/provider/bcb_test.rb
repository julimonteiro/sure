require "test_helper"

class Provider::BcbTest < ActiveSupport::TestCase
  test "uses official PTAX purchase rates and computes the inverse pair" do
    stub_request(:get, /olinda\.bcb\.gov\.br/).to_return(status: 200, body: {
      value: [ { cotacaoCompra: 5.18, cotacaoVenda: 5.19, dataHoraCotacao: "2026-09-30 13:00:00" } ]
    }.to_json)
    provider = Provider::Bcb.new
    forward = provider.fetch_exchange_rate(from: "USD", to: "BRL", date: Date.new(2026, 9, 30))
    inverse = provider.fetch_exchange_rate(from: "BRL", to: "USD", date: Date.new(2026, 9, 30))
    assert forward.success?, forward.error&.message
    assert_equal 5.18.to_d, forward.data.rate
    assert_in_delta 1 / 5.18, inverse.data.rate, 0.0000001
    assert_equal Date.new(2026, 9, 30), inverse.data.date
  end

  test "returns a failure instead of inventing a rate when BCB is unavailable" do
    stub_request(:get, /olinda\.bcb\.gov\.br/).to_return(status: 503, body: "Unavailable")
    response = Provider::Bcb.new.fetch_exchange_rate(from: "USD", to: "BRL", date: Date.new(2026, 9, 30))
    assert_not response.success?
  end
end
