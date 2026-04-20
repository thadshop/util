# SOURCE ONLY — do not execute. Defines fixed inputs for DEK-wrap self-tests.
#
# Loaded by keyring/lib.bash and by keyring/testdata/*.sh. These values are
# not cryptographic policy: they are arbitrary bytes used only to run a local
# openssl enc encrypt/decrypt round-trip (same flags as the active recipe).
#
# Keeping them here (not in dek-wrap-recipe-*.conf) avoids breaking smoke or
# golden-dek-wrapped.bin when editing recipe parameters unrelated to tests.
#
# If you change either value, run keyring/testdata/regen-golden-dek-wrap.sh
# and commit the new golden-dek-wrapped.bin.

SMOKE_PASSPHRASE='keyring-smoke-test-passphrase-do-not-use-for-real'
SMOKE_PLAINTEXT='x'
