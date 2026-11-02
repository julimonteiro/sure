# PTAX reference rates published by Banco Central do Brasil. No account or API
# key is required. USD assets are valued at the reference purchase rate in BRL.
class Provider::Bcb < Provider
  include ExchangeRateConcept
  extend SslConfigurable

  Error = Class.new(Provider::Error)

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      rates = fetch_rates(from, to, date - 7.days, date)
      rates.max_by(&:date) || raise(Error, "BCB não retornou uma cotação para o período solicitado.")
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response { fetch_rates(from, to, start_date, end_date) }
  end

  private
    def fetch_rates(from, to, start_date, end_date)
      unless [ from, to ].sort == %w[BRL USD]
        raise Error, "BCB PTAX supports USD/BRL and BRL/USD."
      end
      response = client.get("CotacaoDolarPeriodo(dataInicial=@dataInicial,dataFinalCotacao=@dataFinalCotacao)", {
        "@dataInicial" => "'#{start_date.strftime('%m-%d-%Y')}'",
        "@dataFinalCotacao" => "'#{end_date.strftime('%m-%d-%Y')}'",
        "$format" => "json", "$top" => 10000
      })
      raise Error, "BCB respondeu HTTP #{response.status}." unless response.success?

      body = JSON.parse(response.body)
      body.fetch("value").map do |item|
        value = BigDecimal(item.fetch("cotacaoCompra").to_s)
        raise Error, "BCB retornou cotação inválida." unless ExchangeRate.valid_rate?(value)
        Rate.new(date: Date.parse(item.fetch("dataHoraCotacao")), from: from, to: to,
          rate: from == "USD" ? value : 1 / value)
      end
    rescue JSON::ParserError, KeyError, Faraday::Error => error
      raise Error, "Não foi possível obter as cotações do BCB (#{error.class.name})."
    end

    def client
      @client ||= Faraday.new(url: "https://olinda.bcb.gov.br/olinda/servico/PTAX/versao/v1/odata/",
        ssl: self.class.faraday_ssl_options) do |connection|
        connection.options.open_timeout = 5
        connection.options.timeout = 20
      end
    end
end
