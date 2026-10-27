#include <stdbool.h>
#include <math.h>

// Bound source dimensions before asking ImageIO for a thumbnail. Network byte
// limits alone do not bound the allocation required by a compressed image.
static inline bool HostImageDimensionsAllowed(double width, double height) {
    return isfinite(width) && isfinite(height) && width > 0 && height > 0 &&
           width <= 16384 && height <= 16384 && width * height <= 20 * 1024 * 1024;
}
