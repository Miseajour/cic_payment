#encoding: utf-8
require 'digest/sha1'
require 'openssl'
require 'payment_settings'
require "view_helpers/form_helpers"

ActionView::Base.send :include, FormHelpers

class CicPayment < PaymentSettings

  cattr_accessor :target_url, :version, :hmac_key, :tpe, :societe, :devise, :url_retour, :url_retour_ok, :url_retour_err
  attr_accessor :date, :montant, :reference, :texte_libre, :lgue, :mail

  @@tpe            = ""
  @@version        = ""
  @@societe        = ""
  @@devise         = "CAD"
  @@hmac_key       = ""
  @@target_url     = ""
  @@url_retour     = ""
  @@url_retour_ok  = ""
  @@url_retour_err = ""

  def initialize

    settings = self.load_settings

    @@tpe            = settings[:tpe]
    @@version        = settings[:version]
    @@societe        = settings[:societe]
    @@devise        = settings[:devise]
    @@hmac_key       = settings[:hmac_key]
    @@target_url     = settings[:target_url]
    @@url_retour     = settings[:url_retour]
    @@url_retour_ok  = settings[:url_retour_ok]
    @@url_retour_err = settings[:url_retour_err]

  end

  def request(payment)

    params = self.load_params(payment)

    @date        = Time.now.strftime(self.date_format)
    @montant     = params[:montant]
    @reference   = params[:reference]

    @texte_libre = params[:texte_libre]
    @lgue        = params[:lgue]
    @mail        = params[:mail]

    return self
  end

  def response(params)
    if verify_hmac(params)
      case params['code-retour']
      when "Annulation"
        params.update(:success => false)
      when "payetest", "paiement"
        params.update(:success => true)
      else
        params.update(:success => false)
      end
    else
      params.update(:success => false)
    end
  end
  
  # === response_mac(params)
  # This function is used to verify that the sent MAC by CIC is the one expected.
  # It calculates the hmac from the correct chain of params. 
  # 
  # The HMAC returned by the bank uses this chain: 
  # <TPE>*<date>*<montant>*<reference>*<texte-libre>*3.0*<code-retour>*
  # <cvx>*<vld>*<brand>*<status3ds>*<numauto>*<motifrefus>*<originecb>*
  # <bincb>*<hpancb>*<ipclient>*<originetr>*<veres>*<pares>*
  #
  # Here is an example of the parameters sent back by the CIC payment module:
  #   Parameters: {"TPE"=>"012345", "date"=>"01/01/2011_a_00:00:00", "montant"=>"10.00EUR", "reference"=>"12_unique_caracters_string", 
  #     "MAC"=>"CalculatedMAC by the bank", 
  #     "texte-libre"=>"{\"custom_id\":1,\"user_id\":1,\"text\":\"Your text\"}", 
  #     "code-retour"=>"payetest", "cvx"=>"oui", "vld"=>"1219", "brand"=>"na", "status3ds"=>"-1", 
  #     "motifrefus"=>"", "originecb"=>"00x", "bincb"=>"000001", "hpancb"=>"F6FBF44A7EC30941DA2E411AA8A50C77F174B2BB", 
  #     "ipclient"=>"01.01.01.01", "originetr"=>"FRA", "veres"=>"", "pares"=>"", "modepaiement"=>"CB"}
  #
  # You can also Use this function for your tests to simulate an exchange with the bank.
  def response_mac params
    
    chain = [
      self.tpe, params['date'], params['montant'], params['reference'], params['texte-libre'], self.version, params['code-retour'], 
      params['cvx'], params['vld'], params['brand'], params['status3ds'], params["numauto"], params['motifrefus'], params['originecb'], 
      params['bincb'], params['hpancb'], params['ipclient'], params['originetr'], params['veres'], params['pares'], ""
    ].join('*')
    
    hmac_token(false, chain)
  end

  def verify_hmac params
    params['MAC'] ? hmac = params['MAC'] : hmac = ""

    # Check if the HMAC matches the HMAC of the data string
    response_mac(params).downcase == hmac.downcase
  end

  # Return the HMAC for a data string
	def hmac_token(form_hmac = true, chain = nil)
    # This chain must contains:
    # <TPE>*<date>*<montant>*<reference>*<texte-libre>*<version>*<lgue>*<societe>*<mail>*
    # <nbrech>*<dateech1>*<montantech1>*<dateech2>*<montantech2>*<dateech3>*<montantech3>*
    # <dateech4>*<montantech4>*<options>
    # For a regular payment, it will be somthing like this: 
    # 1234567*05/12/2006:11:55:23*62.73EUR*ABERTYP00145*ExempleTexteLibre*3.0*FR*monSite1*internaute@sonemail.fr**********
    #
    # So the chain array must contains 9 filled elements + 9 unfilled elements + 1 final star
    # <text-libre>, <lgue> and <mail> are optional, but don't forget to put them in the chain if you decide to add
    # them to the form
    #
    # For a fragmented payment: 
    # 1234567*05/12/2006:11:55:23*62.73EUR*ABERTYP00145*ExempleTexteLibre*3.0*FR*monSite1*internaute@sonemail.fr*
    # 4*05/12/2006*16.23EUR*05/01/2007*15.5EUR*05/02/2007*15.5EUR*05/03/2007*15.5EUR*
    if form_hmac && chain.blank?
      chain = [self.tpe,
          self.date,
          self.montant,
          self.reference,
          self.texte_libre,
          self.version,
          self.lgue,
          self.societe,
          self.mail,
          "", "", "", "", "", "", "", "", "", "" # 10 stars: 9 for fragmented unfilled params + 1 final star 
      ].join("*")
    end

		hmac_sha1(usable_key(self.hmac_key), chain).downcase
	end

protected
  def date_format
    "%d/%m/%Y:%H:%M:%S"
  end

  def hmac_sha1(key, data)
    length = 64

    if (key.length > length)
      key = [Digest::SHA1.hexdigest(key)].pack("H*")
    end

    key  = key.ljust(length, 0.chr)
    ipad = ''.ljust(length, 54.chr)
    opad = ''.ljust(length, 92.chr)

    k_ipad = compute(key, ipad)
    k_opad = compute(key, opad)

    OpenSSL::HMAC.hexdigest(OpenSSL::Digest::Digest.new("sha1"), key, data)
  end

private
	# Return the key to be used in the hmac method
	def usable_key(hmac_key)

		hex_string_key  = hmac_key[0..37]
		hex_final   = hmac_key[38..40] + "00";

		cca0 = hex_final[0].ord

		if cca0 > 70 && cca0 < 97
			hex_string_key += (cca0 - 23).chr + hex_final[1..2]
		elsif hex_final[1..2] == "M"
			hex_string_key += hex_final[0..1] + "0"
		else
			hex_string_key += hex_final[0..2]
		end

		[hex_string_key].pack("H*")
	end

  def compute(key, pad)
    raise ArgumentError, "Can't bitwise-XOR a String with a non-String" \
      unless pad.kind_of? String
    raise ArgumentError, "Can't bitwise-XOR strings of different length" \
      unless key.length == pad.length

    result = (0..key.length-1).collect { |i| key[i].ord ^ pad[i].ord }
    result.pack("C*")
  end
end
