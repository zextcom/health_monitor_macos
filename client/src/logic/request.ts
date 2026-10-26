/**
 * Headers for an API request. `Content-Type: application/json` is only sent together with a body:
 * Fastify rejects a body-less request that declares a JSON body (FST_ERR_CTP_EMPTY_JSON_BODY, 400),
 * which broke every DELETE and the pause/resume POSTs. Caller-supplied headers win.
 */
export function buildRequestHeaders(
  hasBody: boolean,
  extra: Record<string, string> = {},
): Record<string, string> {
  return {
    ...(hasBody ? { 'Content-Type': 'application/json' } : {}),
    ...extra,
  };
}
