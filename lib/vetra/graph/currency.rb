module Vetra
  module Graph
    module Currency
      # ISO 4217 List One (SIX), published 2026-09-17; checked 2026-10-31.
      # https://www.six-group.com/dam/download/financial-information/data-center/iso-currrency/lists/list-one.xml
      # Source SHA-256: 33139b438657d1cee116ba737807ea71d19d6de4b90f799a09c56f0cc6a1b0ff
      # Only codes with a numeric CcyMnrUnts are included. N.A. is not zero.
      EXPONENTS = Data.freeze({
        0 => %w[BIF CLP DJF GNF ISK JPY KMF KRW PYG RWF UGX UYI VND VUV XAF XOF XPF],
        2 => %w[
          AED AFN ALL AMD AOA ARS AUD AWG AZN BAM BBD BDT BMD BND BOB BOV BRL BSD BTN BWP BYN BZD
          CAD CDF CHE CHF CHW CNY COP COU CRC CUP CVE CZK DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP
          GEL GHS GIP GMD GTQ GYD HKD HNL HTG HUF IDR ILS INR IRR JMD KES KGS KHR KPW KYD KZT
          LAK LBP LKR LRD LSL MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD
          NGN NIO NOK NPR NZD PAB PEN PGK PHP PKR PLN QAR RON RSD RUB SAR SBD SCR SDG SEK SGD SHP
          SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TOP TRY TTD TWD TZS UAH USD USN UYU UZS
          VED VES WST XAD XCD XCG YER ZAR ZMW ZWG
        ],
        3 => %w[BHD IQD JOD KWD LYD OMR TND],
        4 => %w[CLF UYW]
      }.flat_map { |exponent, codes| codes.map { |code| [code, exponent] } }.to_h)

      def self.exponent(code)
        EXPONENTS[code]
      end
    end
  end
end
