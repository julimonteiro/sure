# Applies the deterministic parts of a locally read statement. Entries created
# here belong to the import too, so reverting it removes both transfer legs.
class LocalStatementImport
  attr_reader :statement_import

  def initialize(statement_import)
    @statement_import = statement_import
  end

  def valid_account?
    return false unless account && account.currency == data["currency"]
    return account.investment? if data["bank_name"].in?([ "Nomad", "XP" ])
    return account.credit_card? if data["document_type"] == "credit_card_statement"

    account.depository?
  end

  def validate!
    raise ArgumentError, "Escolha uma conta do tipo e da moeda indicados no documento." unless valid_account?
    LocalStatementParser.validate!(data.deep_symbolize_keys)
  end

  def apply!
    close_investment_snapshot!
    create_reserve_transfers!
    match_card_payments!
    match_nomad_transfers!
  end

  private
    def account
      statement_import.account
    end

    def data
      statement_import.extracted_data
    end

    def close_investment_snapshot!
      return unless data["bank_name"] == "Nomad" && data["closing_balance"].present?

      date = Date.iso8601(data.fetch("period_end"))
      amount = data.fetch("closing_balance").to_d
      valuation = account.entries.valuations.find_by(date: date)
      if valuation && valuation.import_id != statement_import.id
        raise ArgumentError, "Já existe outro ajuste de saldo na data de fechamento da Nomad." unless valuation.amount == amount
        return
      end
      valuation ||= account.entries.build(entryable: Valuation.new(kind: "reconciliation"), import: statement_import)
      valuation.update!(date: date, amount: amount, currency: account.currency,
        name: "Fechamento do extrato Nomad", import_locked: true)
    end

    def create_reserve_transfers!
      return unless data["bank_name"] == "Mercado Pago"

      data.fetch("transactions", []).each do |item|
        next if item["reserve_name"].blank?
        source = account.entries.find_by(source: "local_statement", external_id: item["external_id"])
        next unless source&.amount&.positive?
        next if source.entryable.transfer

        name = "Mercado Pago · Reserva #{item['reserve_name'].strip}"
        reserve = account.family.accounts.where(owner_id: account.owner_id).find_or_initialize_by(name: name)
        unless reserve.persisted?
          reserve.assign_attributes(balance: 0, cash_balance: 0, currency: account.currency,
            accountable: Depository.new(subtype: "savings"))
          reserve.save!
        end
        raise ArgumentError, "A conta de reserva precisa ser em #{account.currency}." unless reserve.currency == account.currency
        inflow = Transaction.create!(kind: "funds_movement", entry: Entry.new(
          account: reserve, date: source.date, amount: -source.amount, currency: source.currency,
          name: source.name, notes: "Transferência interna. Saldo anterior da reserva não informado neste extrato.",
          import: statement_import, import_locked: true, source: "local_statement",
          external_id: "reserve-#{source.id}"))
        pair!(source.entryable, inflow)
      end
    end

    def local_imports
      @local_imports ||= account.family.imports.where(type: "PdfImport")
        .where("status = ? OR id = ?", "complete", statement_import.id)
        .includes(:account).select { |item| item.account && item.account.owner_id == account.owner_id && item.local_statement? }
    end

    def match_card_payments!
      local_imports.select { |item| item.extracted_data["document_type"] == "credit_card_statement" }.each do |invoice|
        details = invoice.extracted_data
        next unless details["statement_closing_balance"].present? && details["period_end"].present? && details["due_date"].present?
        bank = details.fetch("bank_name").delete_suffix(" Cartão")
        bank_accounts = local_imports.select { |item| item.extracted_data["bank_name"] == bank }.map(&:account).uniq
        match_recorded_card_payments!(invoice.account, bank_accounts)
        amount = details.fetch("statement_closing_balance").to_d
        next unless amount.positive?
        range = Date.iso8601(details.fetch("period_end"))..(Date.iso8601(details.fetch("due_date")) + 5.days)
        candidates = Entry.where(account: bank_accounts, entryable_type: "Transaction", currency: invoice.account.currency,
          amount: amount, date: range).where("name ~* ?", "PAGAMENTO.*(CARTAO|CARTÃO|FATURA)").to_a
        next unless candidates.one?
        source = candidates.sole
        next if source.entryable.transfer

        existing = invoice.account.entries.transactions.where(amount: -amount, date: (source.date - 3)..(source.date + 3))
          .joins("JOIN transactions payment ON payment.id = entries.entryable_id")
          .where("payment.kind IN (?)", %w[cc_payment funds_movement]).to_a
        next if existing.many?
        inflow = existing.first&.entryable || Transaction.create!(kind: "funds_movement", entry: Entry.new(
          account: invoice.account, date: source.date, amount: -amount, currency: source.currency,
          name: "Pagamento de fatura", notes: "Pagamento identificado no extrato da conta corrente.",
          import: source.import || statement_import, import_locked: true, source: "local_statement",
          external_id: "card-payment-#{source.id}"))
        pair!(source.entryable, inflow)
      end
    end

    def match_recorded_card_payments!(card, bank_accounts)
      card.entries.transactions.joins("JOIN transactions card_payment ON card_payment.id = entries.entryable_id")
        .where("card_payment.kind = ? AND entries.amount < 0", "cc_payment").find_each do |payment|
        next if payment.entryable.transfer
        candidates = Entry.where(account: bank_accounts, entryable_type: "Transaction", currency: payment.currency,
          amount: -payment.amount, date: (payment.date - 3)..(payment.date + 3))
          .where("name ~* ?", "(PAGAMENTO|DÉBITO AUTOMÁTICO).*(FATURA|CARTAO|CARTÃO)").to_a
        candidates.reject! { |candidate| candidate.entryable.transfer }
        pair!(candidates.sole.entryable, payment.entryable) if candidates.one?
      end
    end

    def match_nomad_transfers!
      nomad_accounts = local_imports.select { |item| item.extracted_data["bank_name"] == "Nomad" }.map(&:account).uniq
      return if nomad_accounts.empty?

      source_accounts = local_imports.select { |item| item.extracted_data["bank_name"] == "Santander" }.map(&:account).uniq
      Entry.where(account: source_accounts, entryable_type: "Transaction").where("name ILIKE ?", "%Nomad%").find_each do |outflow|
        next if outflow.entryable.transfer || !outflow.amount.positive?
        candidates = Entry.where(account: nomad_accounts, entryable_type: "Transaction",
          date: (outflow.date - 2)..(outflow.date + 2)).where("name LIKE ?", "DEPOSIT%").select do |inflow|
          next false if inflow.entryable.transfer || !inflow.amount.negative?
          rate = ExchangeRate.where(from_currency: inflow.currency, to_currency: outflow.currency,
            date: (outflow.date - 5)..outflow.date).order(date: :desc).first
          rate && ((-inflow.amount * rate.rate - outflow.amount).abs / outflow.amount) <= 0.1
        end
        pair!(outflow.entryable, candidates.sole.entryable, investment: true) if candidates.one?
      end
    end

    def pair!(outflow, inflow, investment: false)
      return if outflow.transfer || inflow.transfer

      Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow, status: :pending).confirm!
      outflow.update!(kind: "funds_movement", category: nil) if investment
    end
end
