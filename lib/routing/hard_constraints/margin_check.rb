require_relative "base_check"

module Routing
  module HardConstraints
    # Маржа: провайдер не должен стоить дороже, чем берёт мерчант,
    # если только с ним не согласована работа в минус.
    #
    # merchant_margin_pct ищем сперва у заявки, затем у провайдера.
    # Если его нет нигде — сравнивать не с чем, проверка пропускается.
    class MarginCheck < BaseCheck
      REASON = "negative_margin".freeze

      def call(provider, operation, _state)
        return nil if provider.allow_negative_agreement?

        merchant = operation.merchant_margin_pct || provider.merchant_margin_pct
        return nil if merchant.nil?

        return nil if provider.provider_margin_pct <= merchant

        skip(provider, REASON,
             "provider_margin_pct #{fmt(provider.provider_margin_pct)} > " \
             "merchant_margin_pct #{fmt(merchant)}")
      end
    end
  end
end
