// Collection: tokmint_base (tokmint service root).
// Environment: tokmint_profile, tokmint_domain, token_id.

(function () {
    const base = pm.collectionVariables.get('tokmint_base')
        || 'http://127.0.0.1:9876';

    const profile = pm.environment.get('tokmint_profile');
    const dom = pm.environment.get('tokmint_domain');
    const tid = pm.environment.get('token_id');

    const missing = [];
    if (!profile) {
        missing.push('tokmint_profile');
    }
    if (!dom) {
        missing.push('tokmint_domain');
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
        'domain=' + encodeURIComponent(dom),
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
            var scheme = body.token_type;
            if (!scheme || typeof scheme !== 'string') {
                throw new Error('tokmint: missing token_type');
            }

            pm.request.headers.upsert({
                key: 'Authorization',
                value: scheme + ' ' + secret,
            });
        }
    );
})();
