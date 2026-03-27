// Collection: tokmint_base (tokmint service root).
// Environment: tokmint_profile, base_url, token_id,
// optional tokmint_auth_scheme (default SSWS).

(function () {
    const base = pm.collectionVariables.get('tokmint_base')
        || 'http://127.0.0.1:9876';

    const profile = pm.environment.get('tokmint_profile');
    const bu = pm.environment.get('base_url');
    const tid = pm.environment.get('token_id');
    const scheme = (pm.environment.get('tokmint_auth_scheme') || 'SSWS')
        .trim();

    const missing = [];
    if (!profile) {
        missing.push('tokmint_profile');
    }
    if (!bu) {
        missing.push('base_url');
    }
    if (!tid) {
        missing.push('token_id');
    }
    if (missing.length) {
        throw new Error(
            'tokmint: set environment variables: ' + missing.join(', ')
        );
    }

    const q = [
        'profile=' + encodeURIComponent(profile),
        'base_url=' + encodeURIComponent(bu),
        'token_id=' + encodeURIComponent(tid),
    ].join('&');

    const tokUrl = base.replace(/\/$/, '') + '/v1/token?' + q;

    const thisUrl = pm.request.url.toString();
    if (thisUrl.indexOf('/v1/token') !== -1) {
        return;
    }

    pm.sendRequest(
        {
            url: tokUrl,
            method: 'POST',
        },
        function (err, res) {
            if (err) {
                throw new Error('tokmint: ' + err.message);
            }
            if (res.code !== 200) {
                throw new Error('tokmint: HTTP ' + res.code);
            }
            var body;
            try {
                body = res.json();
            } catch (e) {
                throw new Error('tokmint: response was not JSON');
            }
            var secret = body.access_token;
            if (!secret || typeof secret !== 'string') {
                throw new Error('tokmint: missing access_token');
            }

            pm.request.headers.upsert({
                key: 'Authorization',
                value: scheme + ' ' + secret,
            });
        }
    );
})();