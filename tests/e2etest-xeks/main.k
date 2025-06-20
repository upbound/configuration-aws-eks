import models.io.upbound.aws.v1beta1 as awsv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1


_items = [
    metav1alpha1.E2ETest{
        metadata.name: "eks"
        spec= {
            crossplane.autoUpgrade.channel: "Rapid"
            defaultConditions: ["Ready"]
            manifests: [
                platformawsv1alpha1.XEKS{
                    metadata = {
                        name = "configuration-aws-eks"
                    }
                    spec = {
                        parameters = {
                            id = "configuration-aws-eks"
                            region = "us-west-2"
                            accessConfig: {
                                authenticationMode: "CONFIG_MAP"
                                bootstrapClusterCreatorAdminPermissions: True
                            }
                            nodes = {
                                count = 1
                                instanceType = "t3.small"
                            }
                        }
                        writeConnectionSecretToRef = {
                            name = "configuration-aws-eks-kubeconfig"
                            namespace = "upbound-system"
                        }
                    }
                }
                platformawsv1alpha1.XNetwork{
                    metadata = {
                        name = "configuration-aws-eks"
                    }
                    spec = {
                        parameters = {
                            id = "configuration-aws-eks"
                            region = "us-west-2"
                        }
                    }
                }

            ]
            extraResources = [
                # Define the provider configuration
                awsv1beta1.ProviderConfig{
                    metadata.name = "default"
                    spec = {
                        credentials = {
                            source = "Upbound"
                            upbound = {
                                webIdentity = {
                                    roleARN = "arn:aws:iam::609897127049:role/solutions-e2e-provider-aws"
                                }
                            }
                        }
                    }
                }
            ]
            skipDelete: False
            timeoutSeconds: 4500
        }
    }
]
items= _items
