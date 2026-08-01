//go:build cgo && irregex_ffi

package relate

/*
// Pull librelate into the final link so relate_run is visible to the substrate
// runtime's dlsym lookup. Without this, an -tags irregex_ffi build of this
// module would open the engine but find no kinship producer.
#cgo CFLAGS:  -I${SRCDIR}/../../zig-out/include
#cgo LDFLAGS: -L${SRCDIR}/../../zig-out/lib -lrelate -lirregex
#cgo LDFLAGS: -Wl,-rpath,${SRCDIR}/../../zig-out/lib
#include <relate.h>
*/
import "C"
