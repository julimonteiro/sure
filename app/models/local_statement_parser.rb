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
    elsif text.include?("Essa é sua fatura de") && text.include?("Cartão Visa") && text.include?("Mercado Pago")
      MercadoPagoCard.new(pages).parse
    elsif text.include?("DetalhamentodaFatura") && text.include?("TotalaPagar") && text.include?("PAGAMENTODEFATURA")
      SantanderCard.new(pages).parse
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
      lines = text.lines
      lines.each_with_index do |line, index|
        match = line.match(/^\s*(\d{2}-\d{2}-\d{4})\s+(.+?)\s+(\d{10,})\s+R\$\s*(-?[\d.]+,\d{2})\s+R\$\s*[\d.]+,\d{2}/)
        next unless match
        description = match[2].strip
        if description.blank?
          fragments = [lines[index - 1], lines[index + 1]].compact.map(&:strip)
          description = fragments.reject { |part| part.blank? || part.match?(/\d{2}-\d{2}-\d{4}|R\$/) }.join(" ")
        elsif description == "Emergência" && lines[index - 1].to_s.include?("Reserva")
          description = "#{lines[index - 1].strip} #{description}"
        end
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
      lines = text.lines
      lines.each_with_index do |line, index|
        match = line.match(/^\s*(\d{4}-\d{2}-\d{2})\s+(DEPOSIT|CASH_DIVIDEND|WITHDRAWAL)\s+(.+?)\s+(-?[\d,]+\.\d{2})\s+\d+\.\d{2}\s*$/)
        next unless match
        gross = match[4].delete(",").to_d
        transactions << { date: match[1], name: "#{match[2]} #{match[3].strip}",
                          amount: gross,
                          notes: match[2] == "DEPOSIT" ? "Revisar contrapartida da transferência em BRL" : nil }
        if match[2] == "CASH_DIVIDEND" && (rate = lines[index, 6].join.match(/With\s+(\d+(?:\.\d+)?)%\s+NON\s+Resident\s+Alien\s+Withholding/i))
          tax = (gross * rate[1].to_d / 100).round(2)
          transactions << { date: match[1], name: "Imposto retido sobre dividendo", amount: -tax,
                            notes: "#{match[3].strip} · retenção de #{rate[1]}%" }
        end
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

  class MercadoPagoCard < Base
    def parse
      cover = @pages.first
      issue = cover.match(/Emitida em:\s*(\d{2})\/(\d{2})\/(\d{4})/)
      period = cover.match(/Consumos de\s*(\d{2})\/(\d{2})\s+a\s*(\d{2})\/(\d{2})/)
      return unless issue && period

      issue_date = Date.new(issue[3].to_i, issue[2].to_i, issue[1].to_i)
      period_year = period[2].to_i > issue_date.month ? issue_date.year - 1 : issue_date.year
      period_start = Date.new(period_year, period[2].to_i, period[1].to_i)
      lines = @pages.drop(1).take(3).flat_map { |page| page.lines }
      transactions = lines.filter_map do |line|
        match = line.match(/^\s*(\d{2})\/(\d{2})\s+(.+?)\s+R\$\s*([\d.]+,\d{2})\s*$/)
        next unless match

        day, month, description, value = match.captures
        description = description.strip.gsub(/\s+/, " ")
        next if description.blank?

        original_year = month.to_i > issue_date.month ? issue_date.year - 1 : issue_date.year
        original_date = Date.new(original_year, month.to_i, day.to_i)
        statement_date = original_date < period_start ? issue_date - 1.day : original_date
        credit = description.include?("Crédito concedido")
        { date: statement_date.iso8601, name: description,
          amount: amount(value) * (credit ? 1 : -1),
          notes: "Fatura #{issue_date.strftime('%m/%Y')} · compra original #{original_date.strftime('%d/%m/%Y')}#{credit ? ' · origem do crédito a confirmar' : ''}" }
      end
      total = cover[/^\s*Total\s+R\$\s*([\d.]+,\d{2})\s*$/i, 1]
      result("Mercado Pago Cartão", transactions, currency: "BRL")
        .merge(document_type: "credit_card_statement", statement_closing_balance: total.present? ? amount(total) : nil)
    end
  end

  class SantanderCard < Base
    def parse
      cover = @pages.first
      details = @pages[1]
      due = cover.match(/R\$\s*([\d.]+,\d{2})\s+(\d{2})\/(\d{2})\/(\d{4})/)
      cutoff = cover.match(/até\s*(\d{2})\/(\d{2})/)
      return unless due && cutoff && details

      due_date = Date.new(due[4].to_i, due[3].to_i, due[2].to_i)
      cutoff_year = cutoff[2].to_i > due_date.month ? due_date.year - 1 : due_date.year
      cutoff_date = Date.new(cutoff_year, cutoff[2].to_i, cutoff[1].to_i)
      transactions = details.lines.filter_map do |line|
        match = line.match(/^\s*(\d{2})\/(\d{2})\s+(.+?)\s+(-?[\d.]+,\d{2})(?:\s+[\d.]+,\d{2})?\s*$/)
        next unless match

        year = match[2].to_i > cutoff_date.month ? cutoff_date.year - 1 : cutoff_date.year
        original_date = Date.new(year, match[2].to_i, match[1].to_i)
        name = match[3].strip.gsub(/\s+/, " ")
        credit = match[4].start_with?("-")
        posting_date = original_date.month < cutoff_date.month && !name.include?("PAGAMENTODEFATURA") ? cutoff_date : original_date
        { date: posting_date.iso8601, name: name, amount: amount(match[4].delete_prefix("-")) * (credit ? 1 : -1),
          notes: "Fatura #{due_date.strftime('%m/%Y')} · lançamento original #{original_date.strftime('%d/%m/%Y')}" }
      end
      if (iof = details[/IOF DESPESA NO EXTERIOR\s+([\d.]+,\d{2})/, 1])
        transactions << { date: cutoff_date.iso8601, name: "IOF despesa no exterior", amount: -amount(iof),
                          notes: "Fatura #{due_date.strftime('%m/%Y')}" }
      end
      result("Santander Cartão", transactions, currency: "BRL")
        .merge(document_type: "credit_card_statement", statement_closing_balance: amount(due[1]))
    end
  end
end
