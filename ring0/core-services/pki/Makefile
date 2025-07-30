files/root/root-csr.json:
files/intermediate/intermediate-csr.json:
files/config/config.json:

#####################################
# Root
files/root/root-ca-key.pem:
	cfssl gencert -initca files/root/root-csr.json | cfssljson -bare files/root/root-ca

files/root/root-ca.pem:
	cfssl gencert -initca files/root/root-csr.json | cfssljson -bare files/root/root-ca

#####################################
# Intermediate
files/intermediate/intermediate-ca.csr:
	cfssl genkey files/intermediate/intermediate-csr.json | cfssljson -bare files/intermediate/intermediate-ca

files/intermediate/intermediate-ca.pem: files/intermediate/intermediate-csr.json
	cfssl genkey files/intermediate/intermediate-csr.json | cfssljson -bare files/intermediate/intermediate-ca

files/intermediate/intermediate-ca-key.pem: files/root/root-ca.pem files/root/root-ca-key.pem files/config/config.json files/intermediate/intermediate-ca.csr
	cfssl sign -ca files/root/root-ca.pem \
		-ca-key files/root/root-ca-key.pem \
		-config files/config/config.json \
		-profile intermediate files/intermediate/intermediate-ca.csr \
	| cfssljson -bare files/intermediate/intermediate-ca

files/intermediate/intermediate-fullchain.pem: files/intermediate/intermediate-ca-key.pem
	cat files/root/root-ca.pem files/intermediate/intermediate-ca.pem | tee files/intermediate/intermediate-fullchain.pem

#####################################
# Machines

files/certificates/%.json:
	echo $@

files/certificates/%:

.PHONY: destroy-pki
destroy-pki:
	find . -type f -name "*.pem" -exec rm {} \;
	find . -type f -name "*.csr" -exec rm {} \;