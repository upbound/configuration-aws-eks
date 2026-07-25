// Package main generates a CompositionTest
package main

import (
	"encoding/json"
	"fmt"
	"os"

	metav1 "dev.upbound.io/models/io/k8s/meta/v1"
	metav1alpha1 "dev.upbound.io/models/io/upbound/dev/meta/v1alpha1"
	ec2v1beta1 "dev.upbound.io/models/io/upbound/m/aws/ec2/v1beta1"
	eksv1beta1 "dev.upbound.io/models/io/upbound/m/aws/eks/v1beta1"
	platformawsv1alpha1 "dev.upbound.io/models/io/upbound/platform/aws/v1alpha1"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/yaml"
)

// xr builds the inline composite resource (XR) under test: a plain EKS with the
// standard parameters. Reused verbatim as the first assertResource.
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

// observedCluster is the observed EKS Cluster managed resource that carries the
// AWS-computed clusterSecurityGroupId in status.atProvider.vpcConfig. The
// composition reads this id to import a matching SecurityGroup.
func observedCluster() eksv1beta1.Cluster {
	return eksv1beta1.Cluster{
		APIVersion: ptr.To(eksv1beta1.ClusterAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.ClusterKindCluster),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "kubernetesCluster",
			}),
			GenerateName: ptr.To("configuration-aws-eks-"),
			Name:         ptr.To("configuration-aws-eks-kubernetescluster"),
			Namespace:    ptr.To("default"),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": "configuration-aws-eks",
			}),
		},
		Spec: &eksv1beta1.ClusterSpec{
			ManagementPolicies: &[]eksv1beta1.ClusterSpecManagementPoliciesItem{
				eksv1beta1.ClusterSpecManagementPoliciesItemClusterSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.ClusterSpecForProvider{
				Region: ptr.To("us-west-2"),
				AccessConfig: &eksv1beta1.ClusterSpecForProviderAccessConfig{
					AuthenticationMode: ptr.To("API_AND_CONFIG_MAP"),
				},
				RoleArnSelector: &eksv1beta1.ClusterSpecForProviderRoleArnSelector{
					MatchControllerRef: ptr.To(true),
					MatchLabels: ptr.To(map[string]string{
						"role": "controlplane",
					}),
				},
				Version: ptr.To("1.27"),
				VpcConfig: &eksv1beta1.ClusterSpecForProviderVpcConfig{
					EndpointPrivateAccess: ptr.To(true),
					SubnetIDSelector: &eksv1beta1.ClusterSpecForProviderVpcConfigSubnetIDSelector{
						MatchLabels: ptr.To(map[string]string{
							"access": "public",
							"networks.aws.platform.upbound.io/network-id": "configuration-aws-eks",
						}),
					},
				},
			},
			ProviderConfigRef: &eksv1beta1.ClusterSpecProviderConfigRef{
				Kind: ptr.To("ProviderConfig"),
				Name: ptr.To("default"),
			},
		},
		Status: &eksv1beta1.ClusterStatus{
			AtProvider: &eksv1beta1.ClusterStatusAtProvider{
				VpcConfig: &eksv1beta1.ClusterStatusAtProviderVpcConfig{
					ClusterSecurityGroupID: ptr.To("sg-12345678910"),
				},
			},
		},
	}
}

// clusterSecurityGroup is the imported ec2 SecurityGroup the composition is
// expected to render. Its external-name annotation is derived from the observed
// Cluster's clusterSecurityGroupId.
func clusterSecurityGroup() ec2v1beta1.SecurityGroup {
	return ec2v1beta1.SecurityGroup{
		APIVersion: ptr.To(ec2v1beta1.SecurityGroupAPIVersionec2AwsMUpboundIoV1Beta1),
		Kind:       ptr.To(ec2v1beta1.SecurityGroupKindSecurityGroup),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "clusterSecurityGroupImport",
				"crossplane.io/external-name":             "sg-12345678910",
			}),
			GenerateName: ptr.To("configuration-aws-eks-"),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": "configuration-aws-eks",
			}),
		},
		Spec: &ec2v1beta1.SecurityGroupSpec{
			ManagementPolicies: &[]ec2v1beta1.SecurityGroupSpecManagementPoliciesItem{
				ec2v1beta1.SecurityGroupSpecManagementPoliciesItemSecurityGroupSpecManagementPoliciesItem,
			},
			ForProvider: &ec2v1beta1.SecurityGroupSpecForProvider{
				Region: ptr.To("us-west-2"),
				Tags: ptr.To(map[string]string{
					"eks.aws.platform.upbound.io/discovery": "configuration-aws-eks",
				}),
			},
			ProviderConfigRef: &ec2v1beta1.SecurityGroupSpecProviderConfigRef{
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
		clusterSecurityGroup(),
	)

	// Convert typed resources to the spec's observedResources item type.
	observedResources := resourcesToItems[metav1alpha1.CompositionTestSpecObservedResourcesItem](
		observedCluster(),
	)

	// Inline XR: coerce the typed EKS into the spec's inline-XR map type.
	inlineXR := toItem[metav1alpha1.CompositionTestSpecXr](xr())

	test := metav1alpha1.CompositionTest{
		APIVersion: ptr.To(metav1alpha1.CompositionTestAPIVersionmetaDevUpboundIoV1Alpha1),
		Kind:       ptr.To(metav1alpha1.CompositionTestKindCompositionTest),
		Metadata: &metav1.ObjectMeta{
			Name: ptr.To("test-eks-cluster-security-group"),
		},
		Spec: &metav1alpha1.CompositionTestSpec{
			AssertResources:   &assertResources,
			ObservedResources: &observedResources,
			CompositionPath:   ptr.To("apis/eks/composition.yaml"),
			Xr:                &inlineXR,
			XrdPath:           ptr.To("apis/eks/definition.yaml"),
			TimeoutSeconds:    ptr.To(60),
			Validate:          ptr.To(false),
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
