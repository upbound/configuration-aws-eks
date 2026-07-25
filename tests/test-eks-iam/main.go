// Package main generates a CompositionTest
package main

import (
	"encoding/json"
	"fmt"
	"os"

	metav1 "dev.upbound.io/models/io/k8s/meta/v1"
	metav1alpha1 "dev.upbound.io/models/io/upbound/dev/meta/v1alpha1"
	eksv1beta1 "dev.upbound.io/models/io/upbound/m/aws/eks/v1beta1"
	platformawsv1alpha1 "dev.upbound.io/models/io/upbound/platform/aws/v1alpha1"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/yaml"
)

// xr builds the inline composite resource (XR) under test: an EKS with the
// IAM principalArn parameter set. Reused verbatim as the first assertResource.
func xr() platformawsv1alpha1.EKS {
	return platformawsv1alpha1.EKS{
		APIVersion: ptr.To(platformawsv1alpha1.EKSApiVersionawsPlatformUpboundIoV1Alpha1),
		Kind:       ptr.To(platformawsv1alpha1.EKSKindEKS),
		Metadata: &metav1.ObjectMeta{
			Name:      ptr.To("configuration-aws-eks"),
			Namespace: ptr.To("default"),
		},
		Spec: &platformawsv1alpha1.EKSSpec{
			Parameters: &platformawsv1alpha1.EKSSpecParameters{
				ID:     ptr.To("configuration-aws-eks"),
				Region: ptr.To("us-west-2"),
				Nodes: &platformawsv1alpha1.EKSSpecParametersNodes{
					Count:        ptr.To(1),
					InstanceType: ptr.To("t3.small"),
				},
				AccessConfig: &platformawsv1alpha1.EKSSpecParametersAccessConfig{
					AuthenticationMode:                      ptr.To(platformawsv1alpha1.EKSSpecParametersAccessConfigAuthenticationModeAPIANDCONFIGMAP),
					BootstrapClusterCreatorAdminPermissions: ptr.To(true),
				},
				Iam: &platformawsv1alpha1.EKSSpecParametersIam{
					PrincipalArn: ptr.To("arn:12345678910-test"),
				},
			},
		},
	}
}

// accessEntry is the AccessEntry managed resource the composition is expected
// to render for the IAM principalArn.
func accessEntry() eksv1beta1.AccessEntry {
	return eksv1beta1.AccessEntry{
		APIVersion: ptr.To(eksv1beta1.AccessEntryAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.AccessEntryKindAccessEntry),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "1a0d979a32b0482f0df23e1b0bbf7d1ffdf64fabbbf6d912bc958fbc2a9c937b",
			}),
			GenerateName: ptr.To("configuration-aws-eks-"),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": "configuration-aws-eks",
			}),
		},
		Spec: &eksv1beta1.AccessEntrySpec{
			ManagementPolicies: &[]eksv1beta1.AccessEntrySpecManagementPoliciesItem{
				eksv1beta1.AccessEntrySpecManagementPoliciesItemAccessEntrySpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.AccessEntrySpecForProvider{
				ClusterNameSelector: &eksv1beta1.AccessEntrySpecForProviderClusterNameSelector{
					MatchControllerRef: ptr.To(true),
				},
				Region:       ptr.To("us-west-2"),
				Type:         ptr.To("STANDARD"),
				PrincipalArn: ptr.To("arn:12345678910-test"),
			},
			ProviderConfigRef: &eksv1beta1.AccessEntrySpecProviderConfigRef{
				Kind: ptr.To("ProviderConfig"),
				Name: ptr.To("default"),
			},
		},
	}
}

// accessPolicyAssociation is the AccessPolicyAssociation managed resource the
// composition is expected to render, binding the principal to the cluster-admin
// policy.
func accessPolicyAssociation() eksv1beta1.AccessPolicyAssociation {
	return eksv1beta1.AccessPolicyAssociation{
		APIVersion: ptr.To(eksv1beta1.AccessPolicyAssociationAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.AccessPolicyAssociationKindAccessPolicyAssociation),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "39cd6d1ddf3182be30e9af47a93a461fd00b1d0682f933123334e54cd5456f7b",
			}),
			GenerateName: ptr.To("configuration-aws-eks-"),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": "configuration-aws-eks",
			}),
		},
		Spec: &eksv1beta1.AccessPolicyAssociationSpec{
			ManagementPolicies: &[]eksv1beta1.AccessPolicyAssociationSpecManagementPoliciesItem{
				eksv1beta1.AccessPolicyAssociationSpecManagementPoliciesItemAccessPolicyAssociationSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.AccessPolicyAssociationSpecForProvider{
				ClusterNameSelector: &eksv1beta1.AccessPolicyAssociationSpecForProviderClusterNameSelector{
					MatchControllerRef: ptr.To(true),
				},
				Region: ptr.To("us-west-2"),
				AccessScope: &eksv1beta1.AccessPolicyAssociationSpecForProviderAccessScope{
					Type: ptr.To("cluster"),
				},
				PolicyArn: ptr.To("arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"),
				PrincipalArnSelector: &eksv1beta1.AccessPolicyAssociationSpecForProviderPrincipalArnSelector{
					MatchControllerRef: ptr.To(true),
				},
			},
			ProviderConfigRef: &eksv1beta1.AccessPolicyAssociationSpecProviderConfigRef{
				Kind: ptr.To("ProviderConfig"),
				Name: ptr.To("default"),
			},
		},
	}
}

func main() {
	// Convert typed resources to the spec's assertResources item type.
	assertResources := resourcesToItems[metav1alpha1.CompositionTestSpecAssertResourcesItem](
		xr(),
		accessEntry(),
		accessPolicyAssociation(),
	)

	// Inline XR: coerce the typed EKS into the spec's inline-XR map type.
	inlineXR := toItem[metav1alpha1.CompositionTestSpecXr](xr())

	test := metav1alpha1.CompositionTest{
		APIVersion: ptr.To(metav1alpha1.CompositionTestAPIVersionmetaDevUpboundIoV1Alpha1),
		Kind:       ptr.To(metav1alpha1.CompositionTestKindCompositionTest),
		Metadata: &metav1.ObjectMeta{
			Name: ptr.To("eks-iam"),
		},
		Spec: &metav1alpha1.CompositionTestSpec{
			AssertResources: &assertResources,
			CompositionPath: ptr.To("apis/eks/composition.yaml"),
			Xr:              &inlineXR,
			XrdPath:         ptr.To("apis/eks/definition.yaml"),
			TimeoutSeconds:  ptr.To(60),
			Validate:        ptr.To(false),
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
