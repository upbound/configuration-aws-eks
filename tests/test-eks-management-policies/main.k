"""
    ClusterAuth must never inherit a non-default spec.managementPolicies.

    Its controller in provider-upjet-aws is hand-written rather than generated,
    and it never passes managed.WithManagementPolicies(), so a non-default value
    is rejected with "the feature is not enabled" and the resource never syncs.
    Nothing downstream can then read the {id}-ekscluster kubeconfig secret.

    The second assertion is the other half of the proof: a normal composed
    resource must still receive the caller's policy, so the pin is scoped to
    ClusterAuth alone and propagation is untouched.
"""

import models.io.upbound.awsm.eks.v1beta1 as eksv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

# The value configuration-aws-ctp sends for managementMode: Provision, i.e. the
# first real consumer of the non-default path.
_nonDefaultPolicies = ["Observe", "Create", "Update", "LateInitialize"]

_xr = platformawsv1alpha1.EKS {
    metadata: {
        name: "configuration-aws-eks"
        namespace: "default"
    }
    spec: {
        parameters: {
            id: "configuration-aws-eks"
            region: "us-west-2"
            managementPolicies: _nonDefaultPolicies
            nodes: {
                count: 1
                instanceType: "t3.small"
            }
        }
    }
}

# ClusterAuth is only composed once the Cluster reports Ready, so feed a ready
# Cluster in rather than relying on a first-pass render.
_observedCluster = eksv1beta1.Cluster {
    metadata: {
        annotations: {
            "crossplane.io/composition-resource-name": "kubernetesCluster"
        }
        name: "configuration-aws-eks-kubernetescluster"
        namespace: "default"
    }
    spec: {
        forProvider: {
            region: "us-west-2"
        }
    }
    status: {
        atProvider: {
            id: "test-kubernetes-cluster"
        }
        conditions: [
            {
                lastTransitionTime: "2026-01-01T00:00:00Z"
                reason: "Available"
                status: "True"
                type: "Ready"
            }
            {
                lastTransitionTime: "2026-01-01T00:00:00Z"
                reason: "ReconcileSuccess"
                status: "True"
                type: "Synced"
            }
        ]
    }
}

_items = [
    metav1alpha1.CompositionTest {
        metadata.name: "eks-clusterauth-pins-default-management-policy"
        spec = {
            compositionPath: "apis/eks/composition.yaml"
            xrdPath: "apis/eks/definition.yaml"
            timeoutSeconds: 60
            validate: False
            xr: _xr
            observedResources: [
                _observedCluster
            ]
            assertResources: [
                eksv1beta1.ClusterAuth {
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "kubernetesClusterAuth"
                        }
                    }
                    spec: {
                        managementPolicies: ["*"]
                        # forProvider.region is required by the generated model, so a
                        # spec-with-only-managementPolicies fixture will not compile.
                        forProvider: {
                            region: "us-west-2"
                        }
                    }
                }
                eksv1beta1.Cluster {
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "kubernetesCluster"
                        }
                    }
                    spec: {
                        managementPolicies: _nonDefaultPolicies
                        forProvider: {
                            region: "us-west-2"
                        }
                    }
                }
            ]
        }
    }
]
items = _items
