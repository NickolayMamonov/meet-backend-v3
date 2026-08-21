# Bootstrap default proof fixtures

`image-inspect.json` is a secret-free Docker inspection fixture binding one
local image ID to one root digest and the required `linux/amd64` platform.
The executable test creates source repositories and JARs in a temporary
directory, so all byte comparisons and ancestry checks run offline.
