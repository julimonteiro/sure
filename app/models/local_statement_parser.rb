class LocalStatementParser
  def self.parse(content)
    pages = PDF::Reader.new(StringIO.new(content)).pages.map(&:text)
    text = pages.join("\n")
    if text.include?("EXTRATO CONSOLIDADO INTELIGENTE") && text.include?("Conta Corrente")
      Santander.new(pages).parse
    elsif text.include?("EXTRATO DE CONTA") && text.include?("Mercado Pago Instituição")
      MercadoPago.new(pages).parse
    elsif text.include?("Nomad Investment Services Inc.") && text.include?("ACCOUNT SUMMARY")
      Nomad.new(pages).parse
    end
  rescue PDF::Reader::MalformedPDFError
    nil
  end

  class Base
    def initialize(pages)
      @pages = pages
    end

    private

      def amount(value)
        value.delete(".,").to_d / 100
      end

      def result(bank, transactions, opening: nil, closing: nil, currency: "BRL")
        { bank_name: bank, transactions: transactions, opening_balance: opening,
          closing_balance: closing, currency: currency }
      end
  end

  class Santander < Base
    def parse
      page = @pages.find { |p| p.include?("Movimentação") && p.include?("Conta Corrente") }
      return unless page
      year = @pages.join("\n")[/setembro\/(\d{4})/i, 1]
      return unless year

      transactions = []
      date = nil
      page.lines.each do |line|
        break if line.include?("SALDO EM 30/09")
        match = line.match(/^\s*(?:(\d{2}\/\d{2})\s+)?(.+?)\s+(?:-|\d{4,})\s+([\d.]+,\d{2})(-?)\s*(?:[\d.]+,\d{2})?\s*$/)
        next unless match
        date = match[1] if match[1]
        next unless date
        description = match[2].strip
        next if description.start_with?("SALDO")
        value = amount(match[3]) * (match[4] == "-" ? -1 : 1)
        transactions << { date: Date.strptime("#{date}/#{year}", "%d/%m/%Y").iso8601,
                          name: description, amount: value,
                          category: description.include?("LIQUIDO DE VENCIMENTO") ? "Salário" : nil,
                          notes: description.match?(/NOMAD|PAGAMENTO CARTAO/i) ? "Revisar como transferência" : nil }
      end
      result("Santander", transactions)
    end
  end

  class MercadoPago < Base
    def parse
      text = @pages.join("\n")
      period = text.match(/Periodo:\s*De\s*(\d{2}-\d{2}-\d{4})\s*al\s*(\d{2}-\d{2}-\d{4})/)
      return unless period

      transactions = []
      text.lines.each do |line|
        match = line.match(/^\s*(\d{2}-\d{2}-\d{4})\s+(.+?)\s+(\d{10,})\s+R\$\s*(-?[\d.]+,\d{2})\s+R\$\s*[\d.]+,\d{2}/)
        next unless match
        description = match[2].strip
        transactions << { date: Date.strptime(match[1], "%d-%m-%Y").iso8601,
                          name: description, amount: amount(match[4]),
                          category: description.match?(/MELI DEVELOPERS BRASIL|Depósito de salário/i) ? "Salário" : nil,
                          notes: "Operação #{match[3]}#{' · transferência interna' if description.match?(/Reserva por gastos|Reserva programada|Pix enviado Julio Cesar/i)}" }
      end
      result("Mercado Pago", transactions, opening: amount(text[/Saldo inicial:\s*R\$\s*([\d.]+,\d{2})/, 1].to_s),
             closing: amount(text[/Saldo final:\s*R\$\s*([\d.]+,\d{2})/, 1].to_s))
    end
  end

  class Nomad < Base
    def parse
      text = @pages.join("\n")
      period = text.match(/Statement Date:\s*(\d{4}-\d{2}-\d{2})\s*-\s*(\d{4}-\d{2}-\d{2})/)
      return unless period

      transactions = []
      text.lines.each do |line|
        match = line.match(/^\s*(\d{4}-\d{2}-\d{2})\s+(DEPOSIT|CASH_DIVIDEND|WITHDRAWAL)\s+(.+?)\s+(-?[\d,]+\.\d{2})\s+\d+\.\d{2}\s*$/)
        next unless match
        transactions << { date: match[1], name: "#{match[2]} #{match[3].strip}",
                          amount: match[4].delete(",").to_d,
                          notes: match[2] == "DEPOSIT" ? "Revisar contrapartida da transferência em BRL" : nil }
      end
      positions = []
      portfolio = @pages.find { |page| page.include?("PORTFOLIO") && page.include?("Market Value") }
      portfolio&.lines&.each do |line|
        match = line.match(/^\s*(.+?)\s+([A-Z]{1,6})\s+([\d.]+)\s+0\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})/)
        next unless match
        positions << { name: match[1].strip, ticker: match[2], quantity: match[3].to_d,
                       price: match[4].delete(",").to_d, market_value: match[5].delete(",").to_d }
      end
      result("Nomad", transactions, currency: "USD").merge(positions: positions, position_date: period[2])
    end
  end
end
