// This is a copy of postman-prerequest.example-general.js, adapted to enable
// usage of Postman collections provided by SailPoint.
// SailPoint collections need only be modified slightly to work with tokmint.
//
// WARNING:
//   SailPoint's pre-request scripting exposes the access token in an environment
//   variable named `accessToken`.  As this script is meant to enable usage of
//   SailPoint's Postman collection, this script will do that too, if tokmint
//   is not used.
//
// ********************
// What needs to be modified in SailPoint's collection:
// - Add a collection variable named `tokmint-base_url`.  It's value should
//   be the URL to the tokmint service, http://localhost:9876 by default.
// - Set the collection's Auth Type to "No Auth"
// - Add a collection variable named `tokmint-sailpoint-full_domain`.  Its value will
//   be set by this script.
// - SailPoint's collection variable named `baseUrL` should be set to
//   "https://{{tokmint-sailpoint-full_domain}}/<API version path>".  For example,
//   if the API version is 2025, then `baseUrl` should be set to
//   "https://{{tokmint-sailpoint-full_domain}}/v2025".
// ********************

// Structure of this file:
//   • If tokmint-use_prerequest_script is the string "true" → only the
//     tokmint block below runs, then the script stops.
//   • Otherwise → code in the “Non-tokmint” section runs (paste your
//     vendor/token logic there). That section does NOT run when the flag
//     is true.
//
// Requirements for tokmint block:
//  Postman environment variables
//  - Always required:
//    - tokmint-use_prerequest_script = true
//    - tokmint-profile
//    - tokmint-domain
//  - Required for "Mode A" - static token:
//    - tokmint-token_id
//  - Required for "Mode B" - OAuth client_credentials:
//    - tokmint-client_id
//  - Optional for "Mode B" (when your tokmint profile requires them):
//    - tokmint-key_id — required for clients with private_key_jwt (signing key)
//    - tokmint-dpop_key_id — optional; use when DPoP is enabled: required for
//      client_secret + DPoP, or to pick a different key than key_id for the
//      DPoP proof (private_key_jwt + DPoP)

(function () {
    if (pm.environment.get('tokmint-use_prerequest_script') === 'true') {
        console.info('using tokmint pre-request script');
        // ******************************
        // Below here, add any scripting you want to run
        // before the tokmint scripting.
        // vvvvvvvvvvvvvvvvvvvvvvvvvvvvvv


        // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        // Above here, add any scripting you want to run
        // before the tokmint scripting.
        // ******************************

        // Optional: copy values from Environment into Collection variables so
        // {{existing_collection_var}} in URLs/bodies matches e.g.
        // tokmint-domain.
        // Add pairs: [ 'environment_variable_name', 'collection_variable_name' ].
        const _tokmint_env_to_collection = [
            ['tokmint-domain', 'tokmint-sailpoint-full_domain'],
        ];

        for (let i = 0; i < _tokmint_env_to_collection.length; i++) {
            const pair = _tokmint_env_to_collection[i];
            if (!pair || pair.length < 2) {
                continue;
            }
            const envKey = pair[0];
            const collectionKey = pair[1];
            if (!envKey || !collectionKey) {
                continue;
            }
            const raw = pm.environment.get(envKey);
            if (raw === undefined || raw === null) {
                continue;
            }
            const val = String(raw).trim();
            if (val.length) {
                pm.collectionVariables.set(collectionKey, val);
            }
        }

        /**
         * Host:port (or URL tail) for error hints — matches tokmint-base_url.
         */
        function tokmintEndpointLabel(baseUrl) {
            try {
                const u = new URL(String(baseUrl).replace(/\/$/, ''));
                let p = u.port;
                if (!p) {
                    if (u.protocol === 'https:') {
                        p = '443';
                    } else if (u.protocol === 'http:') {
                        p = '80';
                    }
                }
                return p ? u.hostname + ':' + p : u.hostname;
            } catch (e) {
                return String(baseUrl).replace(/\/$/, '');
            }
        }

        /**
         * Log hint for common pm.sendRequest failures; return message suffix.
         */
        function tokmintHintForRequestError(err, baseUrl) {
            const ep = tokmintEndpointLabel(baseUrl);
            const raw = err && err.message ? String(err.message) : String(err);
            const code = err && err.code ? String(err.code) : '';
            const has = function (s) {
                return raw.indexOf(s) !== -1;
            };
            let hint = '';
            if (code === 'ECONNREFUSED' || has('ECONNREFUSED')) {
                hint = ' Is the tokmint service running on ' + ep + '? ' +
                    '(Check collection variable tokmint-base_url.)';
            } else if (code === 'ECONNRESET' || has('ECONNRESET')) {
                hint = ' Connection reset while calling tokmint at ' + ep +
                    ' — server closed the socket or a proxy/TLS mismatch.';
            } else if (code === 'ETIMEDOUT' || code === 'ESOCKETTIMEDOUT' ||
                has('ETIMEDOUT') || has('ESOCKETTIMEDOUT')) {
                hint = ' Timed out reaching tokmint at ' + ep +
                    ' — firewall, VPN, wrong host/port, or service overloaded.';
            } else if (code === 'ENOTFOUND' || has('ENOTFOUND')) {
                hint = ' Host not found for ' + ep +
                    ' — check hostname/DNS and tokmint-base_url.';
            } else if (code === 'EAI_AGAIN' || has('EAI_AGAIN')) {
                hint = ' Temporary DNS failure resolving ' + ep +
                    ' — retry or fix network/DNS.';
            } else if (code === 'EHOSTUNREACH' || has('EHOSTUNREACH')) {
                hint = ' No route to host ' + ep +
                    ' — network path or local/offline interface.';
            } else if (has('certificate') || has('CERT_') ||
                has('unable to verify') || has('SELF_SIGNED') ||
                has('SSL routines') || code === 'ERR_SSL') {
                hint = ' TLS/certificate error calling ' + ep +
                    ' — for local tokmint use http in tokmint-base_url, ' +
                    'or fix trust/proxy settings.';
            }
            if (hint) {
                console.error('tokmint:' + hint);
            }
            return hint;
        }

        const base = pm.collectionVariables.get('tokmint-base_url')
            || 'http://127.0.0.1:9876';

        const profile = pm.environment.get('tokmint-profile');
        const dom = pm.environment.get('tokmint-domain');
        const tidRaw = pm.environment.get('tokmint-token_id');
        const cidRaw = pm.environment.get('tokmint-client_id');

        const tid = tidRaw != null ? String(tidRaw).trim() : '';
        const cid = cidRaw != null ? String(cidRaw).trim() : '';

        const missing = [];
        if (!profile || !String(profile).trim()) {
            missing.push('tokmint-profile');
        }
        if (!dom || !String(dom).trim()) {
            missing.push('tokmint-domain');
        }
        if (missing.length) {
            throw new Error(
                'tokmint: set environment variables: ' + missing.join(', ')
            );
        }

        if (tid !== '' && cid !== '') {
            throw new Error(
                'tokmint: set only one of tokmint-token_id (static) or ' +
                'tokmint-client_id (OAuth client_credentials)'
            );
        }

        let q;
        if (cid !== '') {
            const parts = [
                'profile=' + encodeURIComponent(String(profile).trim()),
                'domain=' + encodeURIComponent(String(dom).trim()),
                'client_id=' + encodeURIComponent(cid),
            ];
            const kidRaw = pm.environment.get('tokmint-key_id');
            const dkidRaw = pm.environment.get('tokmint-dpop_key_id');
            const kid = kidRaw != null ? String(kidRaw).trim() : '';
            const dkid = dkidRaw != null ? String(dkidRaw).trim() : '';
            if (kid !== '') {
                parts.push('key_id=' + encodeURIComponent(kid));
            }
            if (dkid !== '') {
                parts.push('dpop_key_id=' + encodeURIComponent(dkid));
            }
            q = parts.join('&');
        } else if (tid !== '') {
            q = [
                'profile=' + encodeURIComponent(String(profile).trim()),
                'domain=' + encodeURIComponent(String(dom).trim()),
                'token_id=' + encodeURIComponent(tid),
            ].join('&');
        } else {
            throw new Error(
                'tokmint: set tokmint-token_id (Mode A) or ' +
                'tokmint-client_id (Mode B)'
            );
        }

        const tokUrl = base.replace(/\/$/, '') + '/v1/token?' + q;

        const thisUrl = pm.request.url.toString();
        if (thisUrl.indexOf('/v1/token') === -1) {
            pm.sendRequest(
                {
                    url: tokUrl,
                    method: 'POST',
                },
                function (err, res) {
                    if (err) {
                        const hint = tokmintHintForRequestError(err, base);
                        const em = err && err.message
                            ? String(err.message)
                            : String(err);
                        throw new Error('tokmint: ' + em + hint);
                    }
                    if (res.code !== 200) {
                        let detail = 'tokmint: HTTP ' + res.code +
                            ' from tokmint — check profile, domain, and ' +
                            'token_id/client_id/key_id/dpop_key_id; see logs.';
                        if (res.code === 401 || res.code === 403) {
                            detail += ' (Unauthorized often means wrong or ' +
                                'expired secret / OAuth config in tokmint.)';
                        } else if (res.code === 404) {
                            detail += ' (Not found — is tokmint-base_url the ' +
                                'service root, not a path?)';
                        } else if (res.code >= 500) {
                            detail += ' (Server error — inspect tokmint ' +
                                'process output.)';
                        }
                        console.error(detail);
                        throw new Error(detail);
                    }
                    var body;
                    try {
                        body = res.json();
                    } catch (e) {
                        const detail = 'tokmint: response was not JSON — ' +
                            'tokmint may have returned an HTML/plain error ' +
                            'page; confirm URL and that the service is ' +
                            'tokmint.';
                        console.error(detail);
                        throw new Error(detail);
                    }
                    var secret = body.access_token;
                    if (!secret || typeof secret !== 'string') {
                        const detail = 'tokmint: missing access_token in JSON — ' +
                            'tokmint may have returned an error object; check ' +
                            'response body in console/network.';
                        console.error(detail);
                        throw new Error(detail);
                    }
                    var scheme = body.token_type;
                    if (!scheme || typeof scheme !== 'string') {
                        const detail = 'tokmint: missing token_type in JSON — ' +
                            'unexpected response shape from tokmint.';
                        console.error(detail);
                        throw new Error(detail);
                    }

                    pm.request.headers.upsert({
                        key: 'Authorization',
                        value: scheme + ' ' + secret,
                    });
                }
            );
        }

        // ******************************
        // Below here, add any scripting you want to run
        // after the tokmint scripting.
        // vvvvvvvvvvvvvvvvvvvvvvvvvvvvvv


        // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        // Above here, add any scripting you want to run
        // after the tokmint scripting.
        // ******************************

        return;
    }

    // ************************************************************************
    //
    // Section for non-tokmint pre-request scripting.
    //
    // Paste below any scripting you want to run if the environment variable
    // `tokmint-use_prerequest_script` does not exist
    // or is not the string "true".
    // vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv
    console.info('using SailPoint pre-request script, adapted for tokmint');

    // Below is the scripting provided by SailPoint.  Beware that it exposes
    // the access token in an environment variable.  Use this at your own risk.

    const domain = pm.environment.get('domain') ? pm.environment.get('domain') : pm.collectionVariables.get('domain')
    const tokenUrl = 'https://' + pm.environment.get('tenant') + '.api.' + domain + '.com/oauth/token';
    const clientId = pm.environment.get('clientId');
    const clientSecret = pm.environment.get('clientSecret');

    const getTokenRequest = {
        method: 'POST',
        url: tokenUrl,
        body: {
            mode: 'formdata',
            formdata: [{
                    key: 'grant_type',
                    value: 'client_credentials'
                },
                {
                    key: 'client_id',
                    value: clientId
                },
                {
                    key: 'client_secret',
                    value: clientSecret
                }
            ]
        }
    };


    var moment = require('moment');
    if (!pm.environment.has('tokenExpTime')) {
        pm.environment.set('tokenExpTime', moment());
    }

    if (moment(pm.environment.get('tokenExpTime')) <= moment() || !pm.environment.get('tokenExpTime') || !pm.environment.get('accessToken')) {
        var time = moment();
        time.add(12, 'hours');
        pm.environment.set('tokenExpTime', time);
        pm.sendRequest(getTokenRequest, (err, response) => {
            const jsonResponse = response.json();
            if (response.code != 200) {
                throw new Error(`Unable to authenticate: ${JSON.stringify(jsonResponse)}`);
            }
            const newAccessToken = jsonResponse.access_token;
            pm.environment.set('accessToken', newAccessToken);
        });
    }

    // Below is not part of the scripting provided by SailPoint.
    // It is to enable SailPoint's scripting to work with:
    // - The full domain name required by tokmint.
    // - The Postman Auth Type "No Auth" required by tokmint.
    //   (SailPoint's scripting is meant for Auth Type "Bearer Token",
    //   and this avoids having to switch the Auth Type in Postman.)
    console.warn("by SailPoint's design, the access token was exposed as environment variable `accessToken`")
    pm.collectionVariables.set('tokmint-sailpoint-full_domain', pm.environment.get('tenant') + '.api.' + domain + '.com');
    pm.request.headers.upsert({
        key: 'Authorization',
        value: 'Bearer ' + pm.environment.get('accessToken'),
    });

    // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    // Paste above any scripting you want to run if the environment variable
    // `tokmint-use_prerequest_script` does not exist
    // or is not the string "true".
    //
    // ************************************************************************

})();
