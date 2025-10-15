"""
    This test suite validates the sequential creation and readiness of AWS EKS resources.
    Each test step incrementally adds
    resources and verifies their "Ready" condition before proceeding to the next.

    The resource creation flow is validated in the following order:

    Sequence 0:
    - kubernetesCluster
    - kubernetesClusterAuth
    - vpc-cni-addon
    - nodeGroupPublic

    Sequence 1 (after nodeGroupPublic ready):
    - ebsCSIDriverRole
    - eks-pod-identity-agent-addon

    Sequence 2 (after ebsCSIDriverRole ready):
    - ebsCSIDriverPodIdentityAssociation

    Sequence 3 (after ebsCSIDriverPodIdentityAssociation ready):
    - aws-ebs-csi-driver-addon

    Each test (_test1 to _test7) adds new resources and ensures the previously created
    ones have reached a "Ready" status, enforcing the correct creation and dependency order.
"""

import models.io.upbound.aws.eks.v1beta1 as eksv1beta1
import models.io.upbound.aws.eks.v1beta2 as eksv1beta2
import models.io.upbound.aws.iam.v1beta1 as iamv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import resources
import conditions

_spec = metav1alpha1.CompositionTest {
    spec = {
        compositionPath: "apis/composition.yaml"
        xrPath: "examples/eks-xr.yaml"
        xrdPath: "apis/definition.yaml"
        timeoutSeconds: 60
        validate: False
    }
}

_test1 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0"
    **_spec
    spec.assertResources: [
        resources._xr
        resources._kubernetesCluster
        resources._roleControlPlane
        resources._roleNodeGroup
        resources._providerConfigHelm
        resources._providerConfigKubernetes
    ]
}

_test2 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0-cluster-ready"
    **_spec
    spec.observedResources: [
        eksv1beta2.Cluster {
            **resources._kubernetesCluster
            status: {
                atProvider:{
                    id: "test-kubernetes-cluster"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test1.spec.assertResources + [
        _kubernetesClusterAuth
    ]
}

_test3 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0-cluster-auth-ready"
    **_spec
    spec.observedResources: _test2.spec.observedResources + [
        eksv1beta1.ClusterAuth {
            **resources._kubernetesClusterAuth
            status: {
                atProvider: {
                    lastRefreshTime: "12345"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test2.spec.assertResources + [
        resources._vpcCniAddon
    ]
}

_test4 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-0-vpc-cni-addon-ready"
    **_spec
    spec.observedResources: _test3.spec.observedResources + [
        eksv1beta1.Addon {
            **resources._vpcCniAddon
            status: {
                atProvider:{
                    id: "test-vpc-cni-addon"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test3.spec.assertResources + [
        resources._nodeGroupPublic
    ]
}

_test5 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-1-node-group-ready"
    **_spec
    spec.observedResources: _test4.spec.observedResources + [
        eksv1beta2.NodeGroup {
            **resources._nodeGroupPublic
            status: {
                atProvider:{
                    id: "test-node-group-public"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test4.spec.assertResources + [
        resources._ebsCSIDriverRole
        resources._eksPodIdentityAgentAddon
    ]
}

_test6 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-2-ebs-role-ready"
    **_spec
    spec.observedResources: _test5.spec.observedResources + [
        iamv1beta1.Role {
            **resources._ebsCSIDriverRole
            status: {
                atProvider:{
                    id: "test-ebs-csi-driver-role"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test5.spec.assertResources + [
        resources._ebsCSIDriverPodIdentityAssociation
    ]
}

_test7 = metav1alpha1.CompositionTest {
    metadata.name: "sequence-3-pod-identity-ready"
    **_spec
    spec.observedResources: _test6.spec.observedResources + [
        eksv1beta1.PodIdentityAssociation {
            **resources._ebsCSIDriverPodIdentityAssociation
            status: {
                atProvider:{
                    associationId: "test-pod-identity-association"
                }
                conditions: conditions._readyConditions
            }
        }
    ]
    spec.assertResources: _test6.spec.assertResources + [
        resources._awsEbsCsiDriverAddon
    ]
}

items = [_test1, _test2, _test3, _test4, _test5, _test6, _test7]
