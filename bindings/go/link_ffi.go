//go:build cgo && irgx_ffi

package relate

/*
// Pull librelate into the final link so relate_run is visible to the substrate
// runtime's dlsym lookup. Without this, an -tags irgx_ffi build of this
// module would open the engine but find no kinship producer.
#cgo CFLAGS:  -I${SRCDIR}/../../zig-out/include
#cgo LDFLAGS: -L${SRCDIR}/../../zig-out/lib -lrelate -lirgx
#cgo LDFLAGS: -Wl,-rpath,${SRCDIR}/../../zig-out/lib
#include <relate.h>
*/
import "C"
