require 'test_helper'

class QbmsTest < Test::Unit::TestCase
  def setup
    Base.mode = :test

    @gateway = QbmsGateway.new(
      login: 'test',
      ticket: 'abc123',
      pem: 'PEM')

    @amount = 100
    @card = credit_card('4111111111111111')
  end

  def test_successful_authorization
    @gateway.expects(:ssl_post).returns(authorization_response)

    assert response = @gateway.authorize(@amount, @card)
    assert_instance_of Response, response
    assert_success response
    assert_equal '1000', response.authorization
  end

  def test_successful_capture
    @gateway.expects(:ssl_post).returns(capture_response)

    assert response = @gateway.capture(@amount, @card)
    assert_instance_of Response, response
    assert_success response
    assert_equal '1000', response.authorization
  end

  def test_successful_purchase
    @gateway.expects(:ssl_post).returns(charge_response)

    assert response = @gateway.purchase(@amount, @card)
    assert_instance_of Response, response
    assert_success response
    assert_equal '1000', response.authorization
  end

  def test_truncated_address_is_sent
    @gateway.expects(:ssl_post).
      with(anything, regexp_matches(/12345 Ridiculously Lengthy Roa\<.*445566778\</), anything).
      returns(charge_response)

    options = { billing_address: address.update(address1: '12345 Ridiculously Lengthy Road Name', zip: '4455667788') }
    assert response = @gateway.purchase(@amount, @card, options)
    assert_success response
  end

  def test_partial_address_is_ok
    @gateway.expects(:ssl_post).returns(charge_response)

    options = { billing_address: address.update(address1: nil, zip: nil) }
    assert response = @gateway.purchase(@amount, @card, options)
    assert_success response
  end

  def test_successful_void
    @gateway.expects(:ssl_post).returns(void_response)

    assert response = @gateway.void('x')
    assert_instance_of Response, response
    assert_success response
  end

  def test_successful_deprecated_credit
    @gateway.expects(:ssl_post).returns(credit_response)

    assert_deprecation_warning(Gateway::CREDIT_DEPRECATION_MESSAGE) do
      assert response = @gateway.credit(@amount, 'x')
      assert_instance_of Response, response
      assert_success response
    end
  end

  def test_successful_refund
    @gateway.expects(:ssl_post).returns(credit_response)

    assert response = @gateway.refund(@amount, 'x')
    assert_instance_of Response, response
    assert_success response
  end

  def test_avs_result
    @gateway.expects(:ssl_post).returns(authorization_response)
    assert response = @gateway.authorize(@amount, @card)
    assert_equal 'Y', response.avs_result['street_match']
    assert_equal 'Y', response.avs_result['postal_match']

    @gateway.expects(:ssl_post).returns(authorization_response(avs_street: 'Fail'))
    assert response = @gateway.authorize(@amount, @card)
    assert_equal 'N', response.avs_result['street_match']
    assert_equal 'Y', response.avs_result['postal_match']

    @gateway.expects(:ssl_post).returns(authorization_response(avs_zip: 'Fail'))
    assert response = @gateway.authorize(@amount, @card)
    assert_equal 'Y', response.avs_result['street_match']
    assert_equal 'N', response.avs_result['postal_match']

    @gateway.expects(:ssl_post).returns(authorization_response(avs_street: 'Fail', avs_zip: 'Fail'))
    assert response = @gateway.authorize(@amount, @card)
    assert_equal 'N', response.avs_result['street_match']
    assert_equal 'N', response.avs_result['postal_match']
  end

  def test_cvv_result
    @gateway.expects(:ssl_post).returns(authorization_response)
    assert response = @gateway.authorize(@amount, @card)
    assert_equal 'M', response.cvv_result['code']

    @gateway.expects(:ssl_post).returns(authorization_response(card_security_code_match: 'Fail'))
    assert response = @gateway.authorize(@amount, @card)
    assert_equal 'N', response.cvv_result['code']

    @gateway.expects(:ssl_post).returns(authorization_response(card_security_code_match: 'NotAvailable'))
    assert response = @gateway.authorize(@amount, @card)
    assert_equal 'P', response.cvv_result['code']
  end

  def test_successful_query
    @gateway.expects(:ssl_post).returns(query_response)

    assert response = @gateway.query()
    assert_instance_of Response, response
    assert_success response
  end

  def test_failed_signon
    @gateway.expects(:ssl_post).returns(query_response(signon_status_code: 2000))

    assert response = @gateway.query()
    assert_instance_of Response, response
    assert_failure response
  end

  def test_failed_authorization
    @gateway.expects(:ssl_post).returns(authorization_response(status_code: 10301))

    assert response = @gateway.authorize(@amount, @card)
    assert_instance_of Response, response
    assert_failure response
  end

  def test_use_test_url_when_overwriting_with_test_option
    ActiveMerchant::Billing::Base.mode = :production

    @gateway = QbmsGateway.new(login: 'test', ticket: 'abc123', test: true)
    @gateway.stubs(:parse).returns({})
    @gateway.expects(:ssl_post).with(QbmsGateway.test_url, anything, anything).returns(authorization_response)
    @gateway.authorize(@amount, @card)

    ActiveMerchant::Billing::Base.mode = :test
  end

  def test_scrub
    assert @gateway.supports_scrubbing?
    assert_equal @gateway.scrub(pre_scrubbed), post_scrubbed
  end

  # helper methods start here

  def query_response(opts = {})
    wrap 'MerchantAccountQuery', opts, <<-"XML"
      <ConvenienceFees>0.0</ConvenienceFees>
      <CreditCardType>Visa</CreditCardType>
      <CreditCardType>MasterCard</CreditCardType>
      <IsCheckAccepted>true</IsCheckAccepted>
    XML
  end

  def authorization_response(opts = {})
    opts = {
      avs_street: 'Pass',
      avs_zip: 'Pass',
      card_security_code_match: 'Pass',
    }.merge(opts)

    wrap 'CustomerCreditCardAuth', opts, <<-"XML"
      <CreditCardTransID>1000</CreditCardTransID>
      <AuthorizationCode>STRTYPE</AuthorizationCode>
      <AVSStreet>#{opts[:avs_street]}</AVSStreet>
      <AVSZip>#{opts[:avs_zip]}</AVSZip>
      <CardSecurityCodeMatch>#{opts[:card_security_code_match]}</CardSecurityCodeMatch>
      <ClientTransID>STRTYPE</ClientTransID>
    XML
  end

  def capture_response(opts = {})
    wrap 'CustomerCreditCardCapture', opts, <<-"XML"
      <CreditCardTransID>1000</CreditCardTransID>
      <AuthorizationCode>STRTYPE</AuthorizationCode>
      <MerchantAccountNumber>STRTYPE</MerchantAccountNumber>
      <ReconBatchID>STRTYPE</ReconBatchID>
      <ClientTransID>STRTYPE</ClientTransID>
    XML
  end

  def charge_response(opts = {})
    opts = {
      avs_street: 'Pass',
      avs_zip: 'Pass',
      card_security_code_match: 'Pass',
    }.merge(opts)

    wrap 'CustomerCreditCardCharge', opts, <<-"XML"
      <CreditCardTransID>1000</CreditCardTransID>
      <AuthorizationCode>STRTYPE</AuthorizationCode>
      <AVSStreet>#{opts[:avs_street]}</AVSStreet>
      <AVSZip>#{opts[:avs_zip]}</AVSZip>
      <CardSecurityCodeMatch>#{opts[:card_security_code_match]}</CardSecurityCodeMatch>
      <MerchantAccountNumber>STRTYPE</MerchantAccountNumber>
      <ReconBatchID>STRTYPE</ReconBatchID>
      <ClientTransID>STRTYPE</ClientTransID>
    XML
  end

  def void_response(opts = {})
    wrap 'CustomerCreditCardTxnVoid', opts, <<-"XML"
      <CreditCardTransID>1000</CreditCardTransID>
      <ClientTransID>STRTYPE</ClientTransID>
    XML
  end

  def credit_response(opts = {})
    wrap 'CustomerCreditCardTxnVoidOrRefund', opts, <<-"XML"
      <CreditCardTransID>1000</CreditCardTransID>
      <VoidOrRefundTxnType>STRTYPE</VoidOrRefundTxnType>
      <MerchantAccountNumber>STRTYPE</MerchantAccountNumber>
      <ReconBatchID>STRTYPE</ReconBatchID>
      <ClientTransID>STRTYPE</ClientTransID>
    XML
  end

  def wrap(type, opts, xml)
    opts = {
      signon_status_code: 0,
      request_id: 'x',
      status_code: 0,
    }.merge(opts)

    <<-"XML"
     <?xml version="1.0" encoding="utf-8"?>
     <?qbmsxml version="4.0"?>
     <QBMSXML>
       <SignonMsgsRs>
         <SignonAppCertRs statusSeverity='INFO' statusCode='#{opts[:signon_status_code]}' statusMessage="Status OK">
           <ServerDateTime>2010-02-25T01:49:29</ServerDateTime>
           <SessionTicket>abc123</SessionTicket>
         </SignonAppCertRs>
       </SignonMsgsRs>
       <QBMSXMLMsgsRs>
         <#{type}Rs statusCode="#{opts[:status_code]}">
           #{xml}
         </#{type}Rs>
       </QBMSXMLMsgsRs>
     </QBMSXML>
    XML
  end

  def pre_scrubbed
    <<-PRE_SCRUBBED
    <?xml version="1.0" encoding="utf-8"?><?qbmsxml version="4.0"?><QBMSXML><SignonMsgsRq><SignonDesktopRq><ClientDateTime>2012-07-06T11:48:30-07:00</ClientDateTime><ApplicationLogin>subscriptions-test.spreedly.com</ApplicationLogin><ConnectionTicket>TGT-135-0exSkgC_I9tvKAxCwOE$Eg</ConnectionTicket></SignonDesktopRq></SignonMsgsRq><QBMSXMLMsgsRq><CustomerCreditCardChargeRq><TransRequestID>859e649c87f9ac698536</TransRequestID><CreditCardNumber>4111111111111111</CreditCardNumber><ExpirationMonth>9</ExpirationMonth><ExpirationYear>2013</ExpirationYear><IsECommerce>true</IsECommerce><Amount>1.00</Amount><NameOnCard>Longbob Longsen</NameOnCard><CreditCardAddress>1234 My Street</CreditCardAddress><CreditCardPostalCode>K1C2N6</CreditCardPostalCode><CardSecurityCode>123</CardSecurityCode></CustomerCreditCardChargeRq></QBMSXMLMsgsRq></QBMSXML>
    <!DOCTYPE QBMSXML PUBLIC "-//INTUIT//DTD QBMSXML QBMS 4.0//EN" "http://webmerchantaccount.ptc.quickbooks.com/dtds/qbmsxml40.dtd">
    <QBMSXML>
     <SignonMsgsRs>
      <SignonDesktopRs statusCode="0" statusSeverity="INFO">
       <ServerDateTime>2012-07-06T18:48:31</ServerDateTime>
       <SessionTicket>V1-110-Q31341600511142d1e4131:133159303</SessionTicket>
      </SignonDesktopRs>
     </SignonMsgsRs>
     <QBMSXMLMsgsRs>
      <CustomerCreditCardChargeRs statusCode="0" statusMessage="Status OK" statusSeverity="INFO">
       <CreditCardTransID>YY1002519111</CreditCardTransID>
       <AuthorizationCode>135927</AuthorizationCode>
       <AVSStreet>Pass</AVSStreet>
       <AVSZip>Pass</AVSZip>
       <CardSecurityCodeMatch>Pass</CardSecurityCodeMatch>
       <MerchantAccountNumber>5247711053184054</MerchantAccountNumber>
       <ReconBatchID>420120706 1Q11485247711053184054AUTO04</ReconBatchID>
       <PaymentGroupingCode>5</PaymentGroupingCode>
       <PaymentStatus>Completed</PaymentStatus>
       <TxnAuthorizationTime>2012-07-06T18:48:31</TxnAuthorizationTime>
       <TxnAuthorizationStamp>1341600511</TxnAuthorizationStamp>
       <ClientTransID>q0b539f2</ClientTransID>
      </CustomerCreditCardChargeRs>
     </QBMSXMLMsgsRs>
    </QBMSXML>
    PRE_SCRUBBED
  end

  def post_scrubbed
    <<-POST_SCRUBBED
    <?xml version="1.0" encoding="utf-8"?><?qbmsxml version="4.0"?><QBMSXML><SignonMsgsRq><SignonDesktopRq><ClientDateTime>2012-07-06T11:48:30-07:00</ClientDateTime><ApplicationLogin>subscriptions-test.spreedly.com</ApplicationLogin><ConnectionTicket>[FILTERED]</ConnectionTicket></SignonDesktopRq></SignonMsgsRq><QBMSXMLMsgsRq><CustomerCreditCardChargeRq><TransRequestID>859e649c87f9ac698536</TransRequestID><CreditCardNumber>[FILTERED]</CreditCardNumber><ExpirationMonth>9</ExpirationMonth><ExpirationYear>2013</ExpirationYear><IsECommerce>true</IsECommerce><Amount>1.00</Amount><NameOnCard>Longbob Longsen</NameOnCard><CreditCardAddress>1234 My Street</CreditCardAddress><CreditCardPostalCode>K1C2N6</CreditCardPostalCode><CardSecurityCode>[FILTERED]</CardSecurityCode></CustomerCreditCardChargeRq></QBMSXMLMsgsRq></QBMSXML>
    <!DOCTYPE QBMSXML PUBLIC "-//INTUIT//DTD QBMSXML QBMS 4.0//EN" "http://webmerchantaccount.ptc.quickbooks.com/dtds/qbmsxml40.dtd">
    <QBMSXML>
     <SignonMsgsRs>
      <SignonDesktopRs statusCode="0" statusSeverity="INFO">
       <ServerDateTime>2012-07-06T18:48:31</ServerDateTime>
       <SessionTicket>V1-110-Q31341600511142d1e4131:133159303</SessionTicket>
      </SignonDesktopRs>
     </SignonMsgsRs>
     <QBMSXMLMsgsRs>
      <CustomerCreditCardChargeRs statusCode="0" statusMessage="Status OK" statusSeverity="INFO">
       <CreditCardTransID>YY1002519111</CreditCardTransID>
       <AuthorizationCode>135927</AuthorizationCode>
       <AVSStreet>Pass</AVSStreet>
       <AVSZip>Pass</AVSZip>
       <CardSecurityCodeMatch>Pass</CardSecurityCodeMatch>
       <MerchantAccountNumber>5247711053184054</MerchantAccountNumber>
       <ReconBatchID>420120706 1Q11485247711053184054AUTO04</ReconBatchID>
       <PaymentGroupingCode>5</PaymentGroupingCode>
       <PaymentStatus>Completed</PaymentStatus>
       <TxnAuthorizationTime>2012-07-06T18:48:31</TxnAuthorizationTime>
       <TxnAuthorizationStamp>1341600511</TxnAuthorizationStamp>
       <ClientTransID>q0b539f2</ClientTransID>
      </CustomerCreditCardChargeRs>
     </QBMSXMLMsgsRs>
    </QBMSXML>
    POST_SCRUBBED
  end
end
