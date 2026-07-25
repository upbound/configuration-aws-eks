// Package main generates the EKS E2ETest.
//
// This provisions a real controlplane and applies an EKS + Network composite
// (plus the awsm ProviderConfig as an extra resource) to validate end-to-end
// readiness. Ported verbatim from the former KCL fixture (main.k): the typed
// EKS and Network XRs become the spec.manifests, and the awsm ProviderConfig
// becomes the single spec.extraResource.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	metav1 "dev.upbound.io/models/io/k8s/meta/v1"
	metav1alpha1 "dev.upbound.io/models/io/upbound/dev/meta/v1alpha1"
	awsmv1beta1 "dev.upbound.io/models/io/upbound/m/aws/v1beta1"
	platformawsv1alpha1 "dev.upbound.io/models/io/upbound/platform/aws/v1alpha1"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/yaml"
)

const (
	composite = "configuration-aws-eks"
	region    = "us-west-2"
	defaultNS = "default"
)

// eks builds the EKS composite resource applied by the test.
func eks() platformawsv1alpha1.EKS {
	return platformawsv1alpha1.EKS{
		APIVersion: ptr.To(platformawsv1alpha1.EKSApiVersionawsPlatformUpboundIoV1Alpha1),
		Kind:       ptr.To(platformawsv1alpha1.EKSKindEKS),
		Metadata: &metav1.ObjectMeta{
			Name:      ptr.To(composite),
			Namespace: ptr.To(defaultNS),
		},
		Spec: &platformawsv1alpha1.EKSSpec{
			Parameters: &platformawsv1alpha1.EKSSpecParameters{
				ID:     ptr.To(composite),
				Region: ptr.To(region),
				AccessConfig: &platformawsv1alpha1.EKSSpecParametersAccessConfig{
					AuthenticationMode:                      ptr.To(platformawsv1alpha1.EKSSpecParametersAccessConfigAuthenticationModeCONFIGMAP),
					BootstrapClusterCreatorAdminPermissions: ptr.To(true),
				},
				Nodes: &platformawsv1alpha1.EKSSpecParametersNodes{
					Count:        ptr.To(1),
					InstanceType: ptr.To("t3.small"),
				},
			},
		},
	}
}

// network builds the Network composite resource applied by the test.
func network() platformawsv1alpha1.Network {
	return platformawsv1alpha1.Network{
		APIVersion: ptr.To(platformawsv1alpha1.NetworkAPIVersionawsPlatformUpboundIoV1Alpha1),
		Kind:       ptr.To(platformawsv1alpha1.NetworkKindNetwork),
		Metadata: &metav1.ObjectMeta{
			Name:      ptr.To(composite),
			Namespace: ptr.To(defaultNS),
		},
		Spec: &platformawsv1alpha1.NetworkSpec{
			Parameters: &platformawsv1alpha1.NetworkSpecParameters{
				ID:     ptr.To(composite),
				Region: ptr.To(region),
			},
		},
	}
}

// providerConfig builds the awsm ProviderConfig applied as an extra resource.
func providerConfig() awsmv1beta1.ProviderConfig {
	return awsmv1beta1.ProviderConfig{
		APIVersion: ptr.To(awsmv1beta1.ProviderConfigAPIVersionawsMUpboundIoV1Beta1),
		Kind:       ptr.To(awsmv1beta1.ProviderConfigKindProviderConfig),
		Metadata: &metav1.ObjectMeta{
			Name:      ptr.To("default"),
			Namespace: ptr.To(defaultNS),
		},
		Spec: &awsmv1beta1.ProviderConfigSpec{
			Credentials: &awsmv1beta1.ProviderConfigSpecCredentials{
				Source: ptr.To(awsmv1beta1.ProviderConfigSpecCredentialsSourceUpbound),
				Upbound: &awsmv1beta1.ProviderConfigSpecCredentialsUpbound{
					WebIdentity: &awsmv1beta1.ProviderConfigSpecCredentialsUpboundWebIdentity{
						RoleARN: ptr.To("arn:aws:iam::609897127049:role/solutions-e2e-provider-aws"),
					},
				},
			},
		},
	}
}

func main() {
	manifests := resourcesToItems[metav1alpha1.E2ETestSpecManifestsItem](
		eks(),
		network(),
	)
	extraResources := resourcesToItems[metav1alpha1.E2ETestSpecExtraResourcesItem](
		providerConfig(),
	)

	test := metav1alpha1.E2ETest{
		APIVersion: ptr.To(metav1alpha1.E2ETestAPIVersionmetaDevUpboundIoV1Alpha1),
		Kind:       ptr.To(metav1alpha1.E2ETestKindE2ETest),
		Metadata: &metav1.ObjectMeta{
			Name: ptr.To("eks"),
		},
		Spec: &metav1alpha1.E2ETestSpec{
			Crossplane: &metav1alpha1.E2ETestSpecCrossplane{
				AutoUpgrade: &metav1alpha1.E2ETestSpecCrossplaneAutoUpgrade{
					Channel: ptr.To(metav1alpha1.E2ETestSpecCrossplaneAutoUpgradeChannelNone),
				},
				Version: ptr.To("2.0.2-up.5"),
			},
			DefaultConditions: &[]string{"Ready"},
			Manifests:         &manifests,
			ExtraResources:    &extraResources,
			SkipDelete:        ptr.To(false),
			TimeoutSeconds:    ptr.To(4500),
		},
	}

	// Wrap in items array as expected by the test runner
	output := map[string]interface{}{
		"items": []interface{}{test},
	}
	out, err := yaml.Marshal(output)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error encoding YAML: %v\n", err)
		os.Exit(1)
	}
	fmt.Print(string(out))
}

func toItem[T any](resource interface{}) T {
	var item T
	if err := convertViaJSON(&item, resource); err != nil {
		panic(fmt.Sprintf("converting item: %v", err))
	}
	return item
}

func resourcesToItems[T any](resources ...interface{}) []T {
	items := make([]T, 0, len(resources))
	for _, res := range resources {
		items = append(items, toItem[T](res))
	}
	return items
}

func convertViaJSON(to, from any) error {
	bs, err := json.Marshal(from)
	if err != nil {
		return err
	}
	return json.Unmarshal(bs, to)
}
