class LocalStatementParser
  InvalidStatementError = Class.new(ArgumentError)
  UnsupportedStatementError = Class.new(ArgumentError)

  def self.validate!(data)
    raise UnsupportedStatementError, "PDF não reconhecido. Use o extrato ou a fatura original do banco." unless data
    transactions = data.fetch(:transactions)
    unchanged = (data[:opening_balance] && data[:closing_balance] && data[:opening_balance].to_d == data[:closing_balance].to_d) ||
      (data[:opening_cash_balance] && data[:closing_cash_balance] && data[:opening_cash_balance].to_d == data[:closing_cash_balance].to_d)
    if transactions.empty? && data[:positions].blank? && !unchanged
      raise InvalidStatementError, "Nenhuma movimentação foi encontrada neste documento."
    end
    if data[:opening_balance] && data[:closing_balance]
      movement = transactions.sum { |item| item.fetch(:amount).to_d }
      expected = data[:document_type] == "credit_card_statement" ? data[:opening_balance].to_d - movement : data[:opening_balance].to_d + movement
      if (expected - data[:closing_balance].to_d).abs > 0.01.to_d
        raise InvalidStatementError, "Os lançamentos não fecham com os saldos do documento. A importação foi interrompida para evitar valores incompletos."
      end
    end
    if data[:closing_cash_balance] && data[:securities_balance]
      positions_total = data.fetch(:positions).sum { |position| position.fetch(:market_value).to_d }
      unless (positions_total - data[:securities_balance].to_d).abs <= 0.01.to_d
        raise InvalidStatementError, "As posições não fecham com o total de investimentos do extrato."
      end
      if data[:closing_balance] && (positions_total + data[:closing_cash_balance].to_d - data[:closing_balance].to_d).abs > 0.01.to_d
        raise InvalidStatementError, "O caixa e as posições não fecham com o patrimônio total da Nomad."
      end
      cash_movement = transactions.sum { |item| item.fetch(:amount).to_d }
      unless (data.fetch(:opening_cash_balance).to_d + cash_movement - data[:closing_cash_balance].to_d).abs <= 0.01.to_d
        raise InvalidStatementError, "As movimentações de caixa da Nomad não fecham com o extrato. Verifique se há uma operação ainda não suportada."
      end
    end
    data
  end

  def self.parse(content)
    pages = PDF::Reader.new(StringIO.new(content)).pages.map(&:text)
    text = pages.join("\n")
    data = if text.include?("EXTRATO CONSOLIDADO INTELIGENTE") && text.include?("Conta Corrente")
      Santander.new(pages).parse
    elsif text.include?("EXTRATO DE CONTA") && text.include?("Mercado Pago Instituição")
      MercadoPago.new(pages).parse
    elsif text.include?("Nomad Investment Services Inc.") && text.include?("ACCOUNT SUMMARY")
      Nomad.new(pages).parse
    elsif text.include?("Essa é sua fatura de") && text.include?("Cartão Visa") && text.include?("Mercado Pago")
      MercadoPagoCard.new(pages).parse
    elsif text.include?("DetalhamentodaFatura") && text.include?("TotalaPagar") && text.match?(/santander/i)
      SantanderCard.new(pages).parse
    elsif text.include?("XPINVESTIMENTOS") && text.include?("Extratodaconta")
      Xp.new(pages).parse
    end
    return unless data

    required = data[:bank_name] == "Nomad" ? %i[period_start period_end closing_balance opening_cash_balance closing_cash_balance securities_balance] : %i[period_end opening_balance closing_balance]
    if required.any? { |key| data[key].nil? }
      raise InvalidStatementError, "O PDF foi reconhecido, mas faltam datas ou saldos para conferir a importação. Use o documento completo."
    end

    validate!(data)
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
        occurrences = Hash.new(0)
        transactions.each do |item|
          key = Digest::SHA256.hexdigest([ item[:date], item[:reference] || item[:name], item[:amount], item[:reference].present? ? nil : item[:notes] ].join("|"))
          occurrences[key] += 1
          item[:external_id] = "#{bank.parameterize}-#{key}-#{occurrences[key]}"
        end
        { bank_name: bank, transactions: transactions, opening_balance: opening,
          closing_balance: closing, currency: currency, local_parser_version: 2 }
      end
  end

  class Santander < Base
    MONTHS = %w[janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro].freeze

    def parse
      text = @pages.join("\n")
      period = text.match(/(#{MONTHS.join('|')})\s*\/\s*(\d{4})/i)
      return unless period
      year = period[2].to_i
      start_date = Date.new(year, MONTHS.index(period[1].downcase) + 1, 1)
      end_date = start_date.end_of_month
      movement_text = text.split(/Movimentação/, 2).last.to_s
      opening = movement_text[/SALDO EM\s+\d{2}\/\d{2}\s+([\d.]+,\d{2})/, 1]
      closing = text[/Saldo de Conta Corrente em\s+#{end_date.strftime('%d\/%m')}\s+([\d.]+,\d{2})/i, 1] ||
        movement_text[/SALDO EM\s+#{end_date.strftime('%d\/%m')}\s+([\d.]+,\d{2})/, 1]

      transactions = []
      date = nil
      movement_text.lines.each do |line|
        break if line.include?("SALDO EM #{end_date.strftime('%d/%m')}")
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
                          kind: description.match?(/PAGAMENTO CARTAO/i) ? "cc_payment" : "standard",
                          transfer_hint: description.match?(/NOMAD/i) ? "nomad" : (description.match?(/PAGAMENTO CARTAO/i) ? "card_payment" : nil),
                          notes: description.match?(/NOMAD|PAGAMENTO CARTAO/i) ? "Revisar como transferência" : nil }
      end
      result("Santander", transactions, opening: opening && amount(opening), closing: closing && amount(closing))
        .merge(period_start: start_date.iso8601, period_end: end_date.iso8601)
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
          fragments = [ lines[index - 1], lines[index + 1] ].compact.map(&:strip)
          description = fragments.reject { |part| part.blank? || part.match?(/\d{2}-\d{2}-\d{4}|R\$/) }.join(" ")
        elsif lines[index - 1].to_s.strip.match?(/\AReserva (?:por gastos|programada)\z/i)
          description = "#{lines[index - 1].strip} #{description}"
        elsif description.match?(/\AReserva (?:por gastos|programada)\z/i) && lines[index + 1].to_s.strip.match?(/\A[^\d]+\z/)
          description = "#{description} #{lines[index + 1].strip}"
        end
        transactions << { date: Date.strptime(match[1], "%d-%m-%Y").iso8601,
                          name: description, amount: amount(match[4]),
                          reference: match[3],
                          reserve_name: description[/Reserva (?:por gastos|programada)\s+(.+)/i, 1],
                          kind: description.match?(/(?:Pagamento|Débito autom[aá]tico).*?(?:fatura|cart[aã]o)/i) ? "cc_payment" : (description.match?(/Reserva por gastos|Reserva programada/i) ? "funds_movement" : "standard"),
                          category: description.match?(/MELI DEVELOPERS BRASIL|Depósito de salário/i) ? "Salário" : nil,
                          notes: "Operação #{match[3]}#{' · transferência interna' if description.match?(/Reserva por gastos|Reserva programada|Pix enviado Julio Cesar/i)}" }
      end
      opening = text[/Saldo inicial:\s*R\$\s*([\d.]+,\d{2})/, 1]
      closing = text[/Saldo final:\s*R\$\s*([\d.]+,\d{2})/, 1]
      result("Mercado Pago", transactions, opening: opening && amount(opening), closing: closing && amount(closing))
        .merge(period_start: Date.strptime(period[1], "%d-%m-%Y").iso8601,
               period_end: Date.strptime(period[2], "%d-%m-%Y").iso8601)
    end
  end

  class Nomad < Base
    CASH_ACTIVITIES = %w[DEPOSIT CASH_DIVIDEND WITHDRAWAL BUY SELL INTEREST FEE TAX JOURNAL TRANSFER CREDIT DEBIT].freeze

    def parse
      text = @pages.join("\n")
      period = text.match(/Statement Date:\s*(\d{4}-\d{2}-\d{2})\s*-\s*(\d{4}-\d{2}-\d{2})/)
      return unless period

      transactions = []
      lines = text.lines
      lines.each_with_index do |line, index|
        match = line.match(/^\s*(\d{4}-\d{2}-\d{2})\s+([A-Z_]+)\s+(.+?)\s+(-?[\d,]+\.\d{2})\s+\d+\.\d{2}\s*$/)
        next unless match
        next if match[2] == "SWEEP"
        unless CASH_ACTIVITIES.include?(match[2])
          raise InvalidStatementError, "Operação Nomad ainda não suportada: #{match[2]}. Nenhum lançamento foi publicado."
        end
        gross = match[4].delete(",").to_d
        transactions << { date: match[1], name: "#{match[2]} #{match[3].strip}",
                          amount: gross,
                          kind: match[2].in?(%w[DEPOSIT WITHDRAWAL BUY SELL JOURNAL TRANSFER]) ? "funds_movement" : "standard",
                          transfer_hint: match[2] == "DEPOSIT" ? "nomad_deposit" : nil,
                          notes: match[2] == "DEPOSIT" ? "Revisar contrapartida da transferência em BRL" : nil }
        if match[2] == "CASH_DIVIDEND" && (rate = lines[index, 6].join.match(/With\s+(\d+(?:\.\d+)?)%\s+NON\s+Resident\s+Alien\s+Withholding/i))
          tax = (gross * rate[1].to_d / 100).round(2)
          transactions << { date: match[1], name: "Imposto retido sobre dividendo", amount: -tax,
                            notes: "#{match[3].strip} · retenção de #{rate[1]}%" }
        end
      end
      positions = []
      portfolio = text.split(/PORTFOLIO/, 2).last.to_s
      portfolio.lines.each do |line|
        match = line.match(/^\s*(.+?)\s+([A-Z]{1,6})\s+([\d.]+)\s+0\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})/)
        next unless match
        positions << { name: match[1].strip, ticker: match[2], quantity: match[3].to_d,
                       price: match[4].delete(",").to_d, market_value: match[5].delete(",").to_d }
      end
      summary = ->(label) do
        match = text.match(/^\s*#{Regexp.escape(label)}\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s*$/)
        match && [ match[1].delete(",").to_d, match[2].delete(",").to_d ]
      end
      cash = summary.call("Cash Balance")
      fdic = summary.call("FDIC Insured Deposits")
      securities = summary.call("Securities Valuation")
      total = summary.call("Total Net Worth")
      result("Nomad", transactions, currency: "USD").merge(positions: positions, position_date: period[2],
        opening_cash_balance: cash && fdic && cash[0] + fdic[0],
        closing_cash_balance: cash && fdic && cash[1] + fdic[1],
        securities_balance: securities&.last, closing_balance: total&.last,
        period_start: period[1], period_end: period[2])
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
      end_year = period[4].to_i > issue_date.month ? issue_date.year - 1 : issue_date.year
      period_end = Date.new(end_year, period[4].to_i, period[3].to_i)
      lines = @pages.drop(1).flat_map { |page| page.lines }
      transactions = lines.filter_map do |line|
        match = line.match(/^\s*(\d{2})\/(\d{2})\s+(.+?)\s+R\$\s*(-?[\d.]+,\d{2})\s*$/)
        next unless match

        day, month, description, value = match.captures
        description = description.strip.gsub(/\s+/, " ")
        next if description.blank?

        original_year = month.to_i > issue_date.month ? issue_date.year - 1 : issue_date.year
        original_date = Date.new(original_year, month.to_i, day.to_i)
        statement_date = original_date < period_start ? period_end : original_date
        payment = description.match?(/Pagamento (?:da|de) fatura|Débito autom[aá]tico da fatura/i)
        credit = payment || value.start_with?("-") || description.match?(/Crédito concedido|Estorno|Reembolso/i)
        { date: statement_date.iso8601, name: description,
          amount: amount(value.delete_prefix("-")) * (credit ? 1 : -1),
          kind: payment ? "cc_payment" : (description.match?(/Crédito concedido/i) ? "funds_movement" : "standard"),
          notes: "Fatura #{issue_date.strftime('%m/%Y')} · compra original #{original_date.strftime('%d/%m/%Y')}#{credit ? ' · origem do crédito a confirmar' : ''}" }
      end
      total = cover[/^\s*Total\s+R\$\s*([\d.]+,\d{2})\s*$/i, 1]
      previous = cover[/Total da fatura de\s+\S+\s+R\$\s*([\d.]+,\d{2})/i, 1]
      closing = total.present? ? amount(total) : nil
      result("Mercado Pago Cartão", transactions, opening: previous && amount(previous), closing: closing, currency: "BRL")
        .merge(document_type: "credit_card_statement", statement_closing_balance: closing,
               period_start: period_start.iso8601, period_end: period_end.iso8601,
               due_date: cover[/Vence em.*?(\d{2}\/\d{2}\/\d{4})/m, 1]&.then { |value| Date.strptime(value, "%d/%m/%Y").iso8601 })
    end
  end

  class SantanderCard < Base
    def parse
      cover = @pages.first
      details = @pages.drop(1).join("\n")
      due = cover.match(/R\$\s*([\d.]+,\d{2})\s+(\d{2})\/(\d{2})\/(\d{4})/)
      cutoff = cover.match(/até\s*(\d{2})\/(\d{2})/)
      return unless due && cutoff && details

      due_date = Date.new(due[4].to_i, due[3].to_i, due[2].to_i)
      cutoff_year = cutoff[2].to_i > due_date.month ? due_date.year - 1 : due_date.year
      cutoff_date = Date.new(cutoff_year, cutoff[2].to_i, cutoff[1].to_i)
      transactions = details.lines.filter_map do |line|
        match = line.match(/^\s*(?:\d+\s+)?(\d{2})\/(\d{2})\s+(.+?)\s+(-?[\d.]+,\d{2})(?=\s|$)/)
        next unless match

        year = match[2].to_i > cutoff_date.month ? cutoff_date.year - 1 : cutoff_date.year
        original_date = Date.new(year, match[2].to_i, match[1].to_i)
        name = match[3].strip.gsub(/\s+/, " ")
        credit = match[4].start_with?("-")
        posting_date = original_date < cutoff_date.beginning_of_month && !name.include?("PAGAMENTODEFATURA") ? cutoff_date : original_date
        { date: posting_date.iso8601, name: name, amount: amount(match[4].delete_prefix("-")) * (credit ? 1 : -1),
          kind: name.include?("PAGAMENTODEFATURA") ? "cc_payment" : "standard",
          notes: "Fatura #{due_date.strftime('%m/%Y')} · lançamento original #{original_date.strftime('%d/%m/%Y')}" }
      end
      taxes = details.scan(/IOF\s*DESPESA\s*NO\s*EXTERIOR\s+([\d.]+,\d{2})/)
      if taxes.any?
        transactions << { date: cutoff_date.iso8601, name: "IOF despesa no exterior", amount: -taxes.sum { |match| amount(match.first) },
                          notes: "Fatura #{due_date.strftime('%m/%Y')}" }
      end
      previous = @pages.join("\n")[/SaldoAnterior\s+([\d.]+,\d{2})/, 1]
      result("Santander Cartão", transactions, opening: previous && amount(previous), closing: amount(due[1]), currency: "BRL")
        .merge(document_type: "credit_card_statement", statement_closing_balance: amount(due[1]),
               period_end: cutoff_date.iso8601, due_date: due_date.iso8601)
    end
  end

  class Xp < Base
    def parse
      text = @pages.join("\n")
      period = text.match(/De:\s*(\d{2}\/\d{2}\/\d{4})\s*Até:\s*(\d{2}\/\d{2}\/\d{4})/)
      return unless period

      section = text.split(/Lançamentos\s*futuros/i, 2).first
      expected_rows = section.lines.count { |line| line.match?(/^\s*\d{2}\/\d{2}\/\d{4}\s+\d{2}\/\d{2}\/\d{4}/) }
      movements = section.lines.filter_map do |line|
        match = line.match(/^\s*(\d{2}\/\d{2}\/\d{4})\s+(\d{2}\/\d{2}\/\d{4})\s+(.+?)\s+(-?)R\$\s*([\d.]+,\d{2})\s+(-?)R\$\s*([\d.]+,\d{2})\s*$/)
        next unless match

        description = match[3].strip.gsub(/\s+/, " ")
        internal = description.match?(/RETIRADA|OPERAÇÕES\s*EM\s*BOLSA|TRANSFER|APLICA|RESGATE/i)
        { date: Date.strptime(match[1], "%d/%m/%Y").iso8601, name: description,
          amount: amount(match[5]) * (match[4] == "-" ? -1 : 1),
          balance: amount(match[7]) * (match[6] == "-" ? -1 : 1),
          kind: internal ? "funds_movement" : "standard",
          notes: "Movimentação em #{match[2]}. Este documento informa apenas o caixa da XP; não informa o valor da carteira." }
      end.reverse.sort_by { |item| item[:date] }
      if movements.size != expected_rows
        raise InvalidStatementError, "Uma ou mais linhas do extrato XP não puderam ser lidas. Nenhum lançamento foi publicado."
      end
      raise InvalidStatementError, "O extrato XP não informa movimentações e saldos históricos para conferir este período." if movements.empty?
      opening = movements.first.fetch(:balance) - movements.first.fetch(:amount)
      closing = movements.last.fetch(:balance)
      running = opening
      movements.each do |movement|
        running += movement.fetch(:amount)
        if (running - movement.fetch(:balance)).abs > 0.01.to_d
          raise InvalidStatementError, "Os saldos intermediários do extrato XP não fecham com as movimentações."
        end
      end
      result("XP", movements.map { |item| item.except(:balance) }, opening: opening, closing: closing)
        .merge(period_start: Date.strptime(period[1], "%d/%m/%Y").iso8601,
          period_end: Date.strptime(period[2], "%d/%m/%Y").iso8601, cash_only: true)
    end
  end
end
