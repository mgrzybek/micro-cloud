files/root/root-csr.json:
files/intermediate/intermediate-csr.json:
files/config/config.json:

# https://bouchaud.org/blog/en/posts/initializing-root-intermediate-ca-with-cfssl/
#####################################
# Root
files/root/root-ca-key.pem: files/root/root-csr.json
	cfssl gencert -initca files/root/root-csr.json | cfssljson -bare files/root/root-ca

files/root/root-ca.pem: files/root/root-csr.json
	cfssl gencert -initca files/root/root-csr.json | cfssljson -bare files/root/root-ca

#####################################
# Intermediate
files/intermediate/intermediate-ca-key.pem: files/root/root-ca.pem files/root/root-ca-key.pem files/config/config.json
	cfssl genkey files/intermediate/intermediate-csr.json | cfssljson -bare files/intermediate/intermediate-ca
	cfssl sign -ca files/root/root-ca.pem \
		-ca-key files/root/root-ca-key.pem \
		-config files/config/config.json \
		-profile intermediate \
		files/intermediate/intermediate-ca.csr \
	| cfssljson -bare files/intermediate/intermediate-ca

files/intermediate/intermediate-fullchain.pem: files/intermediate/intermediate-ca-key.pem
	cat files/root/root-ca.pem files/intermediate/intermediate-ca.pem | tee files/intermediate/intermediate-fullchain.pem

#####################################
# Tooling
.PHONY: destroy-pki
destroy-pki:
	find . -type f -name "*.pem" -exec rm {} \;
	find . -type f -name "*.csr" -exec rm {} \;