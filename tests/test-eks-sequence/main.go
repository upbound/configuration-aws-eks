// Package main generates the EKS readiness-sequencing CompositionTest suite.
//
// This suite validates the sequential creation and readiness of AWS EKS
// resources. Each case incrementally adds observed resources (marked Ready) and
// asserts that the next resources in the dependency chain appear in the rendered
// desired output. The creation flow is:
//
//	Sequence 0 (created immediately):
//	  - kubernetesCluster, IAM roles (controlplane, nodegroup, ebs-csi-driver),
//	    ebsCSIDriverPodIdentityAssociation, providerConfigs
//	Sequence 1 (after kubernetesCluster ready):        kubernetesClusterAuth
//	Sequence 2 (after kubernetesClusterAuth ready):    vpc-cni-addon
//	Sequence 3 (after vpc-cni-addon ready):            nodeGroupPublic
//	Sequence 4 (after ebsCSIDriverPodIdentityAssociation AND nodeGroupPublic ready):
//	  - aws-ebs-csi-driver-addon, eks-pod-identity-agent-addon
//
// Shared fixtures (formerly resources.k / conditions.k) are Go helper funcs
// returning typed resource structs plus a shared readyConditions() helper.
// Observed resources reuse the same fixtures, wrapped with a Ready status via
// observedWithStatus. The per-phase accumulation is expressed with Go slice
// composition.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	helmv1beta1 "dev.upbound.io/models/io/crossplane/m/helm/v1beta1"
	kubernetesv1alpha1 "dev.upbound.io/models/io/crossplane/m/kubernetes/v1alpha1"
	metav1 "dev.upbound.io/models/io/k8s/meta/v1"
	metav1alpha1 "dev.upbound.io/models/io/upbound/dev/meta/v1alpha1"
	eksv1beta1 "dev.upbound.io/models/io/upbound/m/aws/eks/v1beta1"
	iamv1beta1 "dev.upbound.io/models/io/upbound/m/aws/iam/v1beta1"
	platformawsv1alpha1 "dev.upbound.io/models/io/upbound/platform/aws/v1alpha1"
	"k8s.io/utils/ptr"
	"sigs.k8s.io/yaml"
)

const (
	composite   = "configuration-aws-eks"
	genName     = "configuration-aws-eks-"
	region      = "us-west-2"
	kubeSecret  = "configuration-aws-eks-ekscluster"
	defaultNS   = "default"
	ptrDefault  = "default"
	pcKindValue = "ProviderConfig"
)

// commonSpec returns the fields shared by every CompositionTest case.
func commonSpec() metav1alpha1.CompositionTestSpec {
	return metav1alpha1.CompositionTestSpec{
		CompositionPath: ptr.To("apis/eks/composition.yaml"),
		XrPath:          ptr.To("examples/eks/eks-xr.yaml"),
		XrdPath:         ptr.To("apis/eks/definition.yaml"),
		TimeoutSeconds:  ptr.To(60),
		Validate:        ptr.To(false),
	}
}

// -----------------------------------------------------------------------------
// Shared readiness conditions (formerly conditions.k _readyConditions).
// Rendered as maps because each resource kind has its own generated conditions
// item type; the value is JSON-identical across kinds and only the Ready=True
// signal gates the sequence.
// -----------------------------------------------------------------------------

func readyConditions() []map[string]any {
	const now = "2026-01-01T00:00:00Z"
	return []map[string]any{
		{"reason": "Available", "status": "True", "type": "Ready", "lastTransitionTime": now},
		{"reason": "Success", "status": "True", "type": "LastAsyncOperation", "lastTransitionTime": now},
		{"reason": "ReconcileSuccess", "status": "True", "type": "Synced", "lastTransitionTime": now},
	}
}

// observedWithStatus marshals a typed fixture into a map and layers on an
// observed status (atProvider + Ready conditions), mirroring the KCL
// `**resources._x { status: {...} }` spread used to build observedResources.
func observedWithStatus(base any, atProvider map[string]any) map[string]any {
	m := toMap(base)
	// The render engine `up test` adopted in up v0.49 (PR upbound/up#1524) only
	// hands an observed resource to the function when it carries a concrete,
	// valid metadata.name AND metadata.namespace (these are namespaced managed
	// resources). A generateName-only observed resource is dropped, so the
	// readiness gate (ready()) never sees it and the gated downstream resources
	// never render. Give each observed resource a stable name derived from its
	// composition-resource-name annotation (lowercased to a valid RFC1123 name)
	// plus the default namespace, matching how the import and
	// cluster-security-group suites already set a concrete name+namespace.
	if meta, ok := m["metadata"].(map[string]any); ok {
		if meta["name"] == nil {
			crName := ""
			if ann, ok := meta["annotations"].(map[string]any); ok {
				if s, ok := ann["crossplane.io/composition-resource-name"].(string); ok {
					crName = s
				}
			}
			meta["name"] = strings.ToLower(genName + crName)
		}
		if meta["namespace"] == nil {
			meta["namespace"] = defaultNS
		}
	}
	m["status"] = map[string]any{
		"atProvider": atProvider,
		"conditions": readyConditions(),
	}
	return m
}

// -----------------------------------------------------------------------------
// Shared fixtures (formerly resources.k).
// -----------------------------------------------------------------------------

func xr() platformawsv1alpha1.EKS {
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
				Nodes: &platformawsv1alpha1.EKSSpecParametersNodes{
					Count:        ptr.To(1),
					InstanceType: ptr.To("t3.small"),
				},
			},
		},
	}
}

func kubernetesCluster() eksv1beta1.Cluster {
	return eksv1beta1.Cluster{
		APIVersion: ptr.To(eksv1beta1.ClusterAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.ClusterKindCluster),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "kubernetesCluster",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
		},
		Spec: &eksv1beta1.ClusterSpec{
			ManagementPolicies: &[]eksv1beta1.ClusterSpecManagementPoliciesItem{
				eksv1beta1.ClusterSpecManagementPoliciesItemClusterSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.ClusterSpecForProvider{
				Region: ptr.To(region),
				AccessConfig: &eksv1beta1.ClusterSpecForProviderAccessConfig{
					AuthenticationMode: ptr.To("API_AND_CONFIG_MAP"),
				},
				RoleArnSelector: &eksv1beta1.ClusterSpecForProviderRoleArnSelector{
					MatchControllerRef: ptr.To(true),
					MatchLabels: ptr.To(map[string]string{
						"role": "controlplane",
					}),
				},
				VpcConfig: &eksv1beta1.ClusterSpecForProviderVpcConfig{
					EndpointPrivateAccess: ptr.To(true),
					SubnetIDSelector: &eksv1beta1.ClusterSpecForProviderVpcConfigSubnetIDSelector{
						MatchLabels: ptr.To(map[string]string{
							"access": "public",
							"networks.aws.platform.upbound.io/network-id": composite,
						}),
					},
				},
			},
			ProviderConfigRef: &eksv1beta1.ClusterSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

func roleControlPlane() iamv1beta1.Role {
	return iamv1beta1.Role{
		APIVersion: ptr.To(iamv1beta1.RoleAPIVersioniamAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(iamv1beta1.RoleKindRole),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "controlplaneRole",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
				"role":                    "controlplane",
			}),
		},
		Spec: &iamv1beta1.RoleSpec{
			ManagementPolicies: &[]iamv1beta1.RoleSpecManagementPoliciesItem{
				iamv1beta1.RoleSpecManagementPoliciesItemRoleSpecManagementPoliciesItem,
			},
			ForProvider: &iamv1beta1.RoleSpecForProvider{
				AssumeRolePolicy: ptr.To(`{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "eks.amazonaws.com"
                ]
            },
            "Action": [
                "sts:AssumeRole"
            ]
        }
    ]
  }
`),
				ForceDetachPolicies: ptr.To(true),
				ManagedPolicyArns: &[]string{
					"arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
				},
			},
			ProviderConfigRef: &iamv1beta1.RoleSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

func roleNodeGroup() iamv1beta1.Role {
	return iamv1beta1.Role{
		APIVersion: ptr.To(iamv1beta1.RoleAPIVersioniamAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(iamv1beta1.RoleKindRole),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "nodegroupRole",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
				"role":                    "nodegroup",
			}),
		},
		Spec: &iamv1beta1.RoleSpec{
			ManagementPolicies: &[]iamv1beta1.RoleSpecManagementPoliciesItem{
				iamv1beta1.RoleSpecManagementPoliciesItemRoleSpecManagementPoliciesItem,
			},
			ForProvider: &iamv1beta1.RoleSpecForProvider{
				AssumeRolePolicy: ptr.To(`{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "ec2.amazonaws.com"
                ]
            },
            "Action": [
                "sts:AssumeRole"
            ]
        }
    ]
  }
`),
				ForceDetachPolicies: ptr.To(true),
				ManagedPolicyArns: &[]string{
					"arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
					"arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
					"arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
					"arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
				},
			},
			ProviderConfigRef: &iamv1beta1.RoleSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

func ebsCSIDriverRole() iamv1beta1.Role {
	return iamv1beta1.Role{
		APIVersion: ptr.To(iamv1beta1.RoleAPIVersioniamAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(iamv1beta1.RoleKindRole),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "ebsCSIDriverRole",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
				"role":                    "ebs-csi-driver",
			}),
		},
		Spec: &iamv1beta1.RoleSpec{
			ManagementPolicies: &[]iamv1beta1.RoleSpecManagementPoliciesItem{
				iamv1beta1.RoleSpecManagementPoliciesItemRoleSpecManagementPoliciesItem,
			},
			ForProvider: &iamv1beta1.RoleSpecForProvider{
				AssumeRolePolicy: ptr.To(`{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
`),
				ForceDetachPolicies: ptr.To(true),
				ManagedPolicyArns: &[]string{
					"arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
				},
			},
			ProviderConfigRef: &iamv1beta1.RoleSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

func ebsCSIDriverPodIdentityAssociation() eksv1beta1.PodIdentityAssociation {
	return eksv1beta1.PodIdentityAssociation{
		APIVersion: ptr.To(eksv1beta1.PodIdentityAssociationAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.PodIdentityAssociationKindPodIdentityAssociation),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "ebsCSIDriverPodIdentityAssociation",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
		},
		Spec: &eksv1beta1.PodIdentityAssociationSpec{
			ManagementPolicies: &[]eksv1beta1.PodIdentityAssociationSpecManagementPoliciesItem{
				eksv1beta1.PodIdentityAssociationSpecManagementPoliciesItemPodIdentityAssociationSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.PodIdentityAssociationSpecForProvider{
				Region: ptr.To(region),
				ClusterNameSelector: &eksv1beta1.PodIdentityAssociationSpecForProviderClusterNameSelector{
					MatchControllerRef: ptr.To(true),
				},
				Namespace:      ptr.To("kube-system"),
				ServiceAccount: ptr.To("ebs-csi-controller-sa"),
				RoleArnSelector: &eksv1beta1.PodIdentityAssociationSpecForProviderRoleArnSelector{
					MatchControllerRef: ptr.To(true),
					MatchLabels: ptr.To(map[string]string{
						"role": "ebs-csi-driver",
					}),
				},
			},
			ProviderConfigRef: &eksv1beta1.PodIdentityAssociationSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

func providerConfigHelm() helmv1beta1.ProviderConfig {
	return helmv1beta1.ProviderConfig{
		APIVersion: ptr.To(helmv1beta1.ProviderConfigAPIVersionhelmMCrossplaneIoV1Beta1),
		Kind:       ptr.To(helmv1beta1.ProviderConfigKindProviderConfig),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "providerConfig-helm",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
			Name: ptr.To(composite),
		},
		Spec: &helmv1beta1.ProviderConfigSpec{
			Credentials: &helmv1beta1.ProviderConfigSpecCredentials{
				SecretRef: &helmv1beta1.ProviderConfigSpecCredentialsSecretRef{
					Key:       ptr.To("kubeconfig"),
					Name:      ptr.To(kubeSecret),
					Namespace: ptr.To(defaultNS),
				},
				Source: ptr.To(helmv1beta1.ProviderConfigSpecCredentialsSourceSecret),
			},
		},
	}
}

func providerConfigKubernetes() kubernetesv1alpha1.ProviderConfig {
	return kubernetesv1alpha1.ProviderConfig{
		APIVersion: ptr.To(kubernetesv1alpha1.ProviderConfigAPIVersionkubernetesMCrossplaneIoV1Alpha1),
		Kind:       ptr.To(kubernetesv1alpha1.ProviderConfigKindProviderConfig),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "providerConfig-kubernetes",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
			Name: ptr.To(composite),
		},
		Spec: &kubernetesv1alpha1.ProviderConfigSpec{
			Credentials: &kubernetesv1alpha1.ProviderConfigSpecCredentials{
				SecretRef: &kubernetesv1alpha1.ProviderConfigSpecCredentialsSecretRef{
					Key:       ptr.To("kubeconfig"),
					Name:      ptr.To(kubeSecret),
					Namespace: ptr.To(defaultNS),
				},
				Source: ptr.To(kubernetesv1alpha1.ProviderConfigSpecCredentialsSourceSecret),
			},
		},
	}
}

func kubernetesClusterAuth() eksv1beta1.ClusterAuth {
	return eksv1beta1.ClusterAuth{
		APIVersion: ptr.To(eksv1beta1.ClusterAuthAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.ClusterAuthKindClusterAuth),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "kubernetesClusterAuth",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
		},
		Spec: &eksv1beta1.ClusterAuthSpec{
			ManagementPolicies: &[]eksv1beta1.ClusterAuthSpecManagementPoliciesItem{
				eksv1beta1.ClusterAuthSpecManagementPoliciesItemClusterAuthSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.ClusterAuthSpecForProvider{
				ClusterNameSelector: &eksv1beta1.ClusterAuthSpecForProviderClusterNameSelector{
					MatchControllerRef: ptr.To(true),
				},
				RefreshPeriod: ptr.To("10m0s"),
				Region:        ptr.To(region),
			},
			ProviderConfigRef: &eksv1beta1.ClusterAuthSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
			WriteConnectionSecretToRef: &eksv1beta1.ClusterAuthSpecWriteConnectionSecretToRef{
				Name: ptr.To(kubeSecret),
			},
		},
	}
}

func vpcCniAddon() eksv1beta1.Addon {
	return eksv1beta1.Addon{
		APIVersion: ptr.To(eksv1beta1.AddonAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.AddonKindAddon),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "vpc-cni-addon",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
		},
		Spec: &eksv1beta1.AddonSpec{
			ManagementPolicies: &[]eksv1beta1.AddonSpecManagementPoliciesItem{
				eksv1beta1.AddonSpecManagementPoliciesItemAddonSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.AddonSpecForProvider{
				AddonName: ptr.To("vpc-cni"),
				ClusterNameSelector: &eksv1beta1.AddonSpecForProviderClusterNameSelector{
					MatchControllerRef: ptr.To(true),
				},
				Region:              ptr.To(region),
				ConfigurationValues: ptr.To(`{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}`),
			},
			ProviderConfigRef: &eksv1beta1.AddonSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

func nodeGroupPublic() eksv1beta1.NodeGroup {
	return eksv1beta1.NodeGroup{
		APIVersion: ptr.To(eksv1beta1.NodeGroupAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.NodeGroupKindNodeGroup),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "nodeGroupPublic",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
		},
		Spec: &eksv1beta1.NodeGroupSpec{
			ManagementPolicies: &[]eksv1beta1.NodeGroupSpecManagementPoliciesItem{
				eksv1beta1.NodeGroupSpecManagementPoliciesItemNodeGroupSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.NodeGroupSpecForProvider{
				Region: ptr.To(region),
				ClusterNameSelector: &eksv1beta1.NodeGroupSpecForProviderClusterNameSelector{
					MatchControllerRef: ptr.To(true),
				},
				NodeRoleArnSelector: &eksv1beta1.NodeGroupSpecForProviderNodeRoleArnSelector{
					MatchControllerRef: ptr.To(true),
					MatchLabels: ptr.To(map[string]string{
						"role": "nodegroup",
					}),
				},
				ScalingConfig: &eksv1beta1.NodeGroupSpecForProviderScalingConfig{
					MaxSize: ptr.To[float32](100),
					MinSize: ptr.To[float32](1),
				},
				InstanceTypes: &[]string{"t3.small"},
				SubnetIDSelector: &eksv1beta1.NodeGroupSpecForProviderSubnetIDSelector{
					MatchLabels: ptr.To(map[string]string{
						"networks.aws.platform.upbound.io/network-id": composite,
						"access": "public",
					}),
				},
			},
			InitProvider: &eksv1beta1.NodeGroupSpecInitProvider{
				ScalingConfig: &eksv1beta1.NodeGroupSpecInitProviderScalingConfig{
					DesiredSize: ptr.To[float32](1),
				},
			},
			ProviderConfigRef: &eksv1beta1.NodeGroupSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

func awsEbsCsiDriverAddon() eksv1beta1.Addon {
	return eksv1beta1.Addon{
		APIVersion: ptr.To(eksv1beta1.AddonAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.AddonKindAddon),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "aws-ebs-csi-driver-addon",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
		},
		Spec: &eksv1beta1.AddonSpec{
			ManagementPolicies: &[]eksv1beta1.AddonSpecManagementPoliciesItem{
				eksv1beta1.AddonSpecManagementPoliciesItemAddonSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.AddonSpecForProvider{
				AddonName: ptr.To("aws-ebs-csi-driver"),
				ClusterNameSelector: &eksv1beta1.AddonSpecForProviderClusterNameSelector{
					MatchControllerRef: ptr.To(true),
				},
				Region: ptr.To(region),
			},
			ProviderConfigRef: &eksv1beta1.AddonSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

func eksPodIdentityAgentAddon() eksv1beta1.Addon {
	return eksv1beta1.Addon{
		APIVersion: ptr.To(eksv1beta1.AddonAPIVersioneksAwsMUpboundIoV1Beta1),
		Kind:       ptr.To(eksv1beta1.AddonKindAddon),
		Metadata: &metav1.ObjectMeta{
			Annotations: ptr.To(map[string]string{
				"crossplane.io/composition-resource-name": "eks-pod-identity-agent-addon",
			}),
			GenerateName: ptr.To(genName),
			Labels: ptr.To(map[string]string{
				"crossplane.io/composite": composite,
			}),
		},
		Spec: &eksv1beta1.AddonSpec{
			ManagementPolicies: &[]eksv1beta1.AddonSpecManagementPoliciesItem{
				eksv1beta1.AddonSpecManagementPoliciesItemAddonSpecManagementPoliciesItem,
			},
			ForProvider: &eksv1beta1.AddonSpecForProvider{
				AddonName: ptr.To("eks-pod-identity-agent"),
				ClusterNameSelector: &eksv1beta1.AddonSpecForProviderClusterNameSelector{
					MatchControllerRef: ptr.To(true),
				},
				Region: ptr.To(region),
			},
			ProviderConfigRef: &eksv1beta1.AddonSpecProviderConfigRef{
				Kind: ptr.To(pcKindValue),
				Name: ptr.To(ptrDefault),
			},
		},
	}
}

// -----------------------------------------------------------------------------
// Observed-resource builders (fixture + Ready status), one per phase input.
// The atProvider blobs match the KCL source exactly.
// -----------------------------------------------------------------------------

func observedClusterReady() map[string]any {
	return observedWithStatus(kubernetesCluster(), map[string]any{"id": "test-kubernetes-cluster"})
}

func observedClusterAuthReady() map[string]any {
	return observedWithStatus(kubernetesClusterAuth(), map[string]any{"lastRefreshTime": "12345"})
}

func observedVpcCniAddonReady() map[string]any {
	return observedWithStatus(vpcCniAddon(), map[string]any{"id": "test-vpc-cni-addon"})
}

func observedEbsCSIDriverRoleReady() map[string]any {
	return observedWithStatus(ebsCSIDriverRole(), map[string]any{
		"arn": "arn:aws:iam::123456789012:role/test-ebs-csi-driver-role",
	})
}

func observedPodIdentityAssociationReady() map[string]any {
	return observedWithStatus(ebsCSIDriverPodIdentityAssociation(), map[string]any{
		"associationId": "test-pod-identity-association",
	})
}

func observedNodeGroupReady() map[string]any {
	return observedWithStatus(nodeGroupPublic(), map[string]any{"id": "test-nodegroup-public"})
}

// -----------------------------------------------------------------------------
// CompositionTest assembly with incremental accumulation.
// -----------------------------------------------------------------------------

func makeTest(name string, observed, assert []interface{}) metav1alpha1.CompositionTest {
	spec := commonSpec()

	assertItems := resourcesToItems[metav1alpha1.CompositionTestSpecAssertResourcesItem](assert...)
	spec.AssertResources = &assertItems

	if len(observed) > 0 {
		observedItems := resourcesToItems[metav1alpha1.CompositionTestSpecObservedResourcesItem](observed...)
		spec.ObservedResources = &observedItems
	}

	return metav1alpha1.CompositionTest{
		APIVersion: ptr.To(metav1alpha1.CompositionTestAPIVersionmetaDevUpboundIoV1Alpha1),
		Kind:       ptr.To(metav1alpha1.CompositionTestKindCompositionTest),
		Metadata:   &metav1.ObjectMeta{Name: ptr.To(name)},
		Spec:       &spec,
	}
}

// clone returns a fresh slice so append-based accumulation never aliases a
// prior phase's backing array.
func clone(base []interface{}, extra ...interface{}) []interface{} {
	out := append([]interface{}{}, base...)
	return append(out, extra...)
}

func main() {
	// Sequence 0: everything created immediately (no observed resources).
	assert0 := []interface{}{
		xr(),
		kubernetesCluster(),
		roleControlPlane(),
		roleNodeGroup(),
		ebsCSIDriverRole(),
		ebsCSIDriverPodIdentityAssociation(),
		providerConfigHelm(),
		providerConfigKubernetes(),
	}
	// Sequence 1..4: each phase asserts the prior set plus the newly-ready deps.
	assert1 := clone(assert0, kubernetesClusterAuth())
	assert2 := clone(assert1, vpcCniAddon())
	assert3 := clone(assert2, nodeGroupPublic())
	assert4 := clone(assert3, awsEbsCsiDriverAddon(), eksPodIdentityAgentAddon())

	// Observed sets accumulate as each resource becomes Ready.
	observed2 := []interface{}{observedClusterReady()}
	observed3 := clone(observed2, observedClusterAuthReady())
	observed4 := clone(observed3, observedVpcCniAddonReady())
	observed5 := clone(observed4,
		observedEbsCSIDriverRoleReady(),
		observedPodIdentityAssociationReady(),
		observedNodeGroupReady(),
	)

	items := []interface{}{
		makeTest("sequence-0", nil, assert0),
		makeTest("sequence-0-cluster-ready", observed2, assert1),
		makeTest("sequence-0-cluster-auth-ready", observed3, assert2),
		makeTest("sequence-0-vpc-cni-addon-ready", observed4, assert3),
		makeTest("sequence-0-pod-identity-and-nodegroup-ready", observed5, assert4),
	}

	output := map[string]interface{}{
		"items": items,
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

func toMap(resource interface{}) map[string]any {
	var m map[string]any
	if err := convertViaJSON(&m, resource); err != nil {
		panic(fmt.Sprintf("converting to map: %v", err))
	}
	return m
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
