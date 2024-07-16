import file
import yaml

composition = yaml.decode(file.read("apis/composition-kcl.yaml.template"))

_kcl_step = composition.spec.pipeline[0]

_kcl_step.input.spec.source = file.read("apis/xeks.k")

composition_yaml = yaml.encode(composition)

file.write("apis/composition-kcl.yaml", composition_yaml)
