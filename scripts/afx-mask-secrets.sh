#!/bin/bash
# afx-mask-secrets.sh: stdin -> stdout filter that masks secrets. Put it on the end of every pipeline that
# prints remote or env-derived text. Portable (sed -E only). Masks: URL credentials (scheme://user:pass@),
# KEY/SECRET/TOKEN/PASSWORD/DATABASE_URL-style assignments, Bearer tokens, Stripe/Resend/GitHub/AWS/Anthropic keys,
# JWTs, PEM private-key bodies. Over-masking is acceptable; under-masking is not.
sed -E \
 -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]:]+:[^/@[:space:]]+@#\1***:***@#g' \
 -e 's#([Bb]earer|[Bb]asic)[[:space:]]+[A-Za-z0-9._~+/=-]{8,}#\1 ***#g' \
 -e 's#((^|[^A-Za-z0-9_])[A-Za-z0-9_]*(KEY|SECRET|TOKEN|PASSWORD|PASSWD|PASS|CREDENTIAL|AUTH|DATABASE_URL|DB_URL|DSN|PRIVATE)[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]"'"'"',;]+)#\1***#gI' \
 -e 's#("[A-Za-z0-9_]*(key|secret|token|password|passwd|credential|auth|dsn|private)[A-Za-z0-9_]*"[[:space:]]*:[[:space:]]*)"[^"]*"#\1"***"#gI' \
 -e 's#(sk|rk)_(live|test)_[0-9A-Za-z]{8,}#\1_\2_***#g' \
 -e 's#whsec_[0-9A-Za-z]{8,}#whsec_***#g' \
 -e 's#re_[0-9A-Za-z]{6,}_[0-9A-Za-z]{12,}#re_***#g' \
 -e 's#gh[pousr]_[0-9A-Za-z]{20,}#gh*_***#g' \
 -e 's#AKIA[0-9A-Z]{16}#AKIA***#g' \
 -e 's#sk-ant-[0-9A-Za-z_-]{10,}#sk-ant-***#g' \
 -e 's#eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*#eyJ***.***.***#g' \
 -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\
***PRIVATE KEY MASKED***'
