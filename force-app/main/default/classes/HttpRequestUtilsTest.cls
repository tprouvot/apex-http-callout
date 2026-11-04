/**
 * @description Unit tests for HttpRequestUtils. They pass with and without Nebula Logger deployed.
 **/
@IsTest
private class HttpRequestUtilsTest {
	private static final String URL_SETTING = 'UrlService';
	private static final String NAMED_CREDENTIAL_SETTING = 'NamedCredentialService';
	private static final String BLANK_TIMEOUT_SETTING = 'BlankTimeoutService';

	@TestSetup
	static void setup() {
		insert new List<CalloutSettings__c>{
			new CalloutSettings__c(
				Name = URL_SETTING,
				Endpoint__c = 'https://example.com/api/orders/{0}/lines/{1}',
				Timeout__c = 10000,
				Header1__c = 'Content-Type',
				Value1__c = 'application/json',
				Header3__c = 'X-Client',
				Value3__c = 'apex-http-callout'
			),
			new CalloutSettings__c(Name = NAMED_CREDENTIAL_SETTING, NamedCredentialApiName__c = 'TestCredential', Endpoint__c = 'orders', Timeout__c = 5000),
			new CalloutSettings__c(Name = BLANK_TIMEOUT_SETTING, Endpoint__c = 'https://example.com/api/ping', Timeout__c = null)
		};
	}

	@IsTest
	static void getSetsEndpointParamsAndHeadersWithoutBody() {
		CalloutMock mock = new CalloutMock(200, '{"ok":true}');
		Test.setMock(HttpCalloutMock.class, mock);

		Test.startTest();
		HttpResponse res = HttpRequestUtils.getHttpResponse(URL_SETTING, new List<String>{ 'A1', '2' }, 'GET', '{"ignored":true}', 'test');
		Test.stopTest();

		Assert.areEqual(200, res.getStatusCode(), 'The mocked response is returned');
		Assert.areEqual('https://example.com/api/orders/A1/lines/2', mock.lastRequest.getEndpoint(), 'Endpoint params are merged into Endpoint__c');
		Assert.areEqual('GET', mock.lastRequest.getMethod(), 'Method is passed through');
		Assert.areEqual('application/json', mock.lastRequest.getHeader('Content-Type'), 'Header1/Value1 is set');
		Assert.areEqual('apex-http-callout', mock.lastRequest.getHeader('X-Client'), 'Header3/Value3 is set even when Header2 is blank');
		Assert.isTrue(String.isBlank(mock.lastRequest.getBody()), 'The body is only sent for POST');
		Assert.areEqual(mock.lastRequest.getEndpoint(), HttpRequestUtils.getLastHttpRequest().getEndpoint(), 'The last request is kept');
	}

	@IsTest
	static void postSendsBodyThroughNamedCredential() {
		CalloutMock mock = new CalloutMock(201, '{"id":"42"}');
		Test.setMock(HttpCalloutMock.class, mock);

		Test.startTest();
		HttpResponse res = HttpRequestUtils.getHttpResponse(NAMED_CREDENTIAL_SETTING, null, 'POST', '{"name":"test"}', 'test');
		Test.stopTest();

		Assert.areEqual(201, res.getStatusCode(), 'The mocked response is returned');
		Assert.areEqual('callout:TestCredential/orders', mock.lastRequest.getEndpoint(), 'The Named Credential prefixes the endpoint');
		Assert.areEqual('POST', mock.lastRequest.getMethod(), 'Method is passed through');
		Assert.areEqual('{"name":"test"}', mock.lastRequest.getBody(), 'The body is sent for POST');
	}

	@IsTest
	static void errorStatusIsReturnedToTheCaller() {
		Test.setMock(HttpCalloutMock.class, new CalloutMock(500, 'Server error'));

		Test.startTest();
		HttpResponse res = HttpRequestUtils.getHttpResponse(URL_SETTING, new List<String>{ 'A1', '2' }, 'GET', '', 'test');
		Test.stopTest();

		Assert.areEqual(500, res.getStatusCode(), 'Status codes >= 400 do not throw');
		Assert.areEqual('Server error', res.getBody(), 'The error body is returned');
		Assert.isNotNull(HttpRequestUtils.getLastHttpRequest(), 'The last request is kept on error status');
	}

	@IsTest
	static void calloutExceptionIsRethrown() {
		CalloutMock mock = new CalloutMock(0, null);
		mock.exceptionToThrow = new CalloutException('Read timed out');
		Test.setMock(HttpCalloutMock.class, mock);

		Test.startTest();
		try {
			HttpRequestUtils.getHttpResponse(URL_SETTING, new List<String>{ 'A1', '2' }, 'GET', '', 'test');
			Assert.fail('A CalloutException was expected');
		} catch (CalloutException e) {
			Assert.areEqual('Read timed out', e.getMessage(), 'The original exception is rethrown');
			HttpRequest lastRequest = HttpRequestUtils.getLastHttpRequest();
			Assert.isNotNull(lastRequest, 'The failed request is kept, so the caller can log it');
			Assert.areEqual('https://example.com/api/orders/A1/lines/2', lastRequest.getEndpoint(), 'The kept request is the one that failed');
		}
		Test.stopTest();
	}

	@IsTest
	static void lastRequestIsTheFailedOneAfterAnEarlierSuccess() {
		CalloutMock mock = new CalloutMock(200, '{"ok":true}');
		Test.setMock(HttpCalloutMock.class, mock);

		Test.startTest();
		HttpRequestUtils.getHttpResponse(NAMED_CREDENTIAL_SETTING, null, 'GET', '', 'first call');
		mock.exceptionToThrow = new CalloutException('Read timed out');
		try {
			HttpRequestUtils.getHttpResponse(URL_SETTING, new List<String>{ 'B2', '3' }, 'GET', '', 'second call');
			Assert.fail('A CalloutException was expected');
		} catch (CalloutException e) {
			Assert.areEqual(
				'https://example.com/api/orders/B2/lines/3',
				HttpRequestUtils.getLastHttpRequest().getEndpoint(),
				'The kept request is the failed second call, not the successful first one'
			);
		}
		Test.stopTest();
	}

	@IsTest
	static void unknownSettingThrowsConfigException() {
		Test.setMock(HttpCalloutMock.class, new CalloutMock(200, '{"ok":true}'));

		Test.startTest();
		try {
			HttpRequestUtils.getHttpResponse('DoesNotExist', null, 'GET', '', 'test');
			Assert.fail('A CalloutConfigException was expected');
		} catch (HttpRequestUtils.CalloutConfigException e) {
			Assert.isTrue(e.getMessage().contains('"DoesNotExist"'), 'The message names the missing setting: ' + e.getMessage());
		}
		Test.stopTest();
	}

	@IsTest
	static void validTimeoutIsUsedAsIs() {
		Assert.areEqual(10000, HttpRequestUtils.getTimeout(URL_SETTING, 10000), 'A timeout within the Apex range is kept');
		Assert.areEqual(1, HttpRequestUtils.getTimeout(URL_SETTING, 1), 'The minimum Apex timeout is kept');
		Assert.areEqual(HttpRequestUtils.MAX_TIMEOUT_MS, HttpRequestUtils.getTimeout(URL_SETTING, 120000), 'The maximum Apex timeout is kept');
	}

	@IsTest
	static void blankOrNonPositiveTimeoutFallsBackToDefault() {
		for (Decimal timeout : new List<Decimal>{ null, 0, -5000, 0.5 }) {
			Assert.areEqual(HttpRequestUtils.DEFAULT_TIMEOUT_MS, HttpRequestUtils.getTimeout(URL_SETTING, timeout), 'Timeout ' + timeout + ' falls back to the default');
		}
	}

	@IsTest
	static void timeoutAboveApexMaximumIsCapped() {
		Assert.areEqual(HttpRequestUtils.MAX_TIMEOUT_MS, HttpRequestUtils.getTimeout(URL_SETTING, 120001), 'Just above the maximum is capped');
		Assert.areEqual(HttpRequestUtils.MAX_TIMEOUT_MS, HttpRequestUtils.getTimeout(URL_SETTING, 999999), 'The field maximum is capped');
	}

	@IsTest
	static void calloutWithBlankTimeoutIsSent() {
		Assert.isNull(CalloutSettings__c.getInstance(BLANK_TIMEOUT_SETTING).Timeout__c, 'The setting under test has a blank Timeout__c');
		CalloutMock mock = new CalloutMock(200, '{"ok":true}');
		Test.setMock(HttpCalloutMock.class, mock);

		Test.startTest();
		HttpResponse res = HttpRequestUtils.getHttpResponse(BLANK_TIMEOUT_SETTING, null, 'GET', '', 'test');
		Test.stopTest();

		Assert.areEqual(200, res.getStatusCode(), 'A blank Timeout__c no longer prevents the callout');
		Assert.areEqual('https://example.com/api/ping', mock.lastRequest.getEndpoint(), 'The callout was sent');
	}

	@IsTest
	static void standardHeaderValuesAreLoggable() {
		Assert.areEqual('application/json', HttpRequestUtils.getLoggableHeaderValue('Content-Type', 'application/json'), 'Content-Type is not secret');
		Assert.areEqual('application/json', HttpRequestUtils.getLoggableHeaderValue(' ACCEPT ', 'application/json'), 'The header name is case-insensitive and trimmed');
		Assert.areEqual('abc-123', HttpRequestUtils.getLoggableHeaderValue('X-Correlation-Id', 'abc-123'), 'Correlation ids are not secret');
	}

	@IsTest
	static void otherHeaderValuesAreMasked() {
		for (String header : new List<String>{ 'Authorization', 'x-api-key', 'Ocp-Apim-Subscription-Key', 'X-Auth-Token', 'Cookie', 'X-Client', 'X-Signature' }) {
			Assert.areEqual('[masked]', HttpRequestUtils.getLoggableHeaderValue(header, 'Bearer s3cr3t'), header + ' value must be masked');
		}
		Assert.areEqual('[masked]', HttpRequestUtils.getLoggableHeaderValue(null, 's3cr3t'), 'A null header name is masked');
		Assert.isNull(HttpRequestUtils.getLoggableHeaderValue('Authorization', null), 'Nothing to mask in a null value');
	}

	private class CalloutMock implements HttpCalloutMock {
		private Integer statusCode;
		private String body;
		public HttpRequest lastRequest;
		public Exception exceptionToThrow;

		CalloutMock(Integer statusCode, String body) {
			this.statusCode = statusCode;
			this.body = body;
		}

		/**
		 * @description Keeps the request, then throws exceptionToThrow or returns the configured response
		 * @param req request sent by HttpRequestUtils
		 * @return HttpResponse
		 */
		public HttpResponse respond(HttpRequest req) {
			this.lastRequest = req;
			if (this.exceptionToThrow != null) {
				throw this.exceptionToThrow;
			}
			HttpResponse res = new HttpResponse();
			res.setStatusCode(this.statusCode);
			res.setBody(this.body);
			return res;
		}
	}
}
