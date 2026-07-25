module github.com/upbound/configuration-aws-eks/tests/e2etest-eks

go 1.24.9

require (
	dev.upbound.io/models v0.0.0
	k8s.io/utils v0.0.0-20241104163129-6fe5fd82f078
	sigs.k8s.io/yaml v1.4.0
)

require (
	github.com/apapsch/go-jsonmerge/v2 v2.0.0 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/oapi-codegen/runtime v1.6.0 // indirect
)

replace dev.upbound.io/models => ../../.up/go/models
