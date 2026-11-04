/**
 * @description Makes outbound HTTP callouts configured by CalloutSettings__c records.
 * Nebula Logger lines are commented out with the "// [nebula] " marker and can be enabled at deploy time.
 * @see https://github.com/tprouvot/apex-http-callout
 **/
public inherited sharing class HttpRequestUtils {
	private static final String API_NAME_SUFFIX = '__c';
	private static final String HEADER = 'Header';
	private static final String VALUE = 'Value';
	private static HttpRequest request;
	private static final String MASKED_VALUE = '[masked]';
	// Same value as the default of the Timeout__c field
	@TestVisible
	private static final Integer DEFAULT_TIMEOUT_MS = 5000;
	// Apex accepts a timeout from 1 to 120,000 ms; Timeout__c accepts up to 999,999
	@TestVisible
	private static final Integer MAX_TIMEOUT_MS = 120000;
	// Only these headers have their value written to the logs. Any other header value is masked,
	// so a secret in a custom header (API key, token, signature...) can never leak into the logs.
	// Hardcoded on purpose, so that every change goes through code review: see "Sensitive data in the logs" in README.md.
	// Names in lower case. Never add a header that can carry a credential, a session or a signature.
	private static final Set<String> LOGGABLE_HEADERS = new Set<String>{
		'accept',
		'accept-charset',
		'accept-encoding',
		'accept-language',
		'cache-control',
		'content-encoding',
		'content-language',
		'content-type',
		'user-agent',
		'x-correlation-id',
		'x-request-id'
	};

	/**
	 * @description Thrown when the CalloutSettings__c record needed for a callout is missing
	 **/
	public class CalloutConfigException extends Exception {
	}

	/**
	 * @description Makes the callout configured by a CalloutSettings__c record and returns the response
	 * @param settingName Name of the CalloutSettings__c record to use (endpoint, Named Credential, timeout, headers)
	 * @param endpointParams values for the {0}, {1}... placeholders of Endpoint__c, not URL-encoded. Null when there are none.
	 * @param method HTTP method, for example GET or POST
	 * @param reqBody request body, sent only when method is POST
	 * @param loggingMessage text added after the setting name in the Nebula log entries, for example to identify the business record
	 * @return the HTTPResponse, also when the status is 400 or above: the caller checks the status code
	 * @throws CalloutConfigException when no CalloutSettings__c record is named settingName
	 * @throws System.CalloutException when the callout fails (timeout, DNS, TLS...), after logging it
	 */
	public static HTTPResponse getHttpResponse(String settingName, List<String> endpointParams, String method, String reqBody, String loggingMessage) {
		HttpRequest req = new HttpRequest();
		// Kept before anything can throw, so that getLastHttpRequest() never returns the request of a previous callout
		request = req;
		HTTPResponse res;
		CalloutSettings__c settings = CalloutSettings__c.getInstance(settingName);
		if (settings == null) {
			String message = 'No CalloutSettings__c record named "' + settingName + '"';
			// [nebula] Logger.error(message).addTag('Callout: ' + settingName);
			throw new CalloutConfigException(message);
		}
		try {
			String endPointToUse = settings.Endpoint__c != null && endpointParams != null ? String.format(settings.Endpoint__c, endpointParams) : settings.Endpoint__c;

			//set the necessary header and the value.
			for (Integer i = 1; i <= 6; i++) {
				// 6 header/value pairs: Header1__c/Value1__c to Header6__c/Value6__c
				String header = (String) settings.get(HEADER + i + API_NAME_SUFFIX);
				if (String.isNotBlank(header)) {
					String value = (String) settings.get(VALUE + i + API_NAME_SUFFIX);
					req.setHeader(header, value);
					// [nebula] Logger.fine(header + ' ' + getLoggableHeaderValue(header, value));
				}
			}
			req.setTimeout(getTimeout(settingName, settings.Timeout__c));
			req.setMethod(method);

			if ('POST'.equals(method)) {
				req.setBody(reqBody);
			}
			req.setEndpoint(settings.NamedCredentialApiName__c == null ? endPointToUse : 'callout:' + settings.NamedCredentialApiName__c + '/' + endPointToUse);

			//Everything set => do the callout
			res = new Http().send(req);
			if (res.getStatusCode() < 400) {
				//everything ok => log only in fine mode
				// [nebula] Logger.fine(settingName + ' ' + loggingMessage).setHttpRequestDetails(req).setHttpResponseDetails(res);
			} else {
				//we have an error => log it as error
				// [nebula] Logger.error(settingName + ' ' + loggingMessage).setHttpRequestDetails(req).setHttpResponseDetails(res).addTag('Callout: ' + settingName);
			}
		} catch (System.CalloutException e) {
			// [nebula] Logger.error(settingName + ' ' + loggingMessage, e).setHttpRequestDetails(req).setHttpResponseDetails(res).addTag('Callout: ' + settingName);
			throw e;
		}

		return res;
	}

	/**
	 * @description Returns a timeout that Apex accepts. A blank, zero or negative Timeout__c falls back to
	 * DEFAULT_TIMEOUT_MS, a value above MAX_TIMEOUT_MS is capped, decimals are rounded down.
	 * @param settingName CalloutSettings__c record name, for the log message
	 * @param configuredTimeout Timeout__c value
	 * @return timeout in milliseconds, from 1 to MAX_TIMEOUT_MS
	 */
	@TestVisible
	private static Integer getTimeout(String settingName, Decimal configuredTimeout) {
		if (configuredTimeout == null || configuredTimeout < 1) {
			// [nebula] Logger.warn(settingName + ': Timeout__c is ' + configuredTimeout + ', using ' + DEFAULT_TIMEOUT_MS + ' ms').addTag('Callout: ' + settingName);
			return DEFAULT_TIMEOUT_MS;
		}
		if (configuredTimeout > MAX_TIMEOUT_MS) {
			// [nebula] Logger.warn(settingName + ': Timeout__c is ' + configuredTimeout + ', capped to ' + MAX_TIMEOUT_MS + ' ms').addTag('Callout: ' + settingName);
			return MAX_TIMEOUT_MS;
		}
		return configuredTimeout.intValue();
	}

	/**
	 * @description Returns a header value that is safe to write to a log: the value itself for the standard,
	 * non-secret headers in LOGGABLE_HEADERS (Accept, Content-Type...), "[masked]" for every other header.
	 * Use it as well when logging the headers of getLastHttpRequest() from the calling code.
	 * @param headerName header name, case-insensitive
	 * @param value header value
	 * @return the value, or "[masked]"
	 */
	public static String getLoggableHeaderValue(String headerName, String value) {
		if (String.isBlank(value)) {
			return value;
		}
		return headerName != null && LOGGABLE_HEADERS.contains(headerName.trim().toLowerCase()) ? value : MASKED_VALUE;
	}

	/**
	 * @description Returns the request built by the last getHttpResponse call in this transaction,
	 * also when that call threw. Header values are not masked: use getLoggableHeaderValue before logging them.
	 * @return HttpRequest, or null when getHttpResponse was not called in this transaction
	 */
	public static HttpRequest getLastHttpRequest() {
		return request;
	}
}
