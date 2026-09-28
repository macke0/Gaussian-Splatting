# 3D Gaussian Splatting: Mathematical Architecture & Code Mapping

This document bridges the gap between the continuous mathematics of 3D Gaussian Splatting and its discrete implementation in this repository's CUDA rasterization pipeline. 

Unlike implicit neural fields (NeRFs), Gaussian Splatting is an **explicit** volumetric representation. The scene is composed of millions of 3D Gaussians, which are sorted, projected, and alpha-blended in real-time. 

## 1. The 3D Gaussian Representation 

Every point in the scene is a 3D Gaussian, defined mathematically by its mean $\mu$ (position) and its covariance matrix $\Sigma$ (shape/scale):

$G(x) = e^{-\frac{1}{2}(x-\mu)^T \Sigma^{-1} (x-\mu)}$

### The Covariance Matrix Challenge
For a covariance matrix to represent a valid physical volume, it must be positive semi-definite. If we optimized the 9 parameters of $\Sigma$ directly via gradient descent, the matrix would quickly become mathematically invalid. 

**Code Translation:** To guarantee validity during optimization, the codebase decomposes the covariance matrix into a scaling matrix $S$ (stored as a 3D vector) and a rotation matrix $R$ (stored as a quaternion). 

In the forward pass, the valid covariance matrix is reconstructed:
$\Sigma = R S S^T R^T$

## 2. View-Dependent Color via Spherical Harmonics 

Real-world materials reflect light differently depending on the viewing angle. Instead of storing a single static RGB color per Gaussian, we store **Spherical Harmonics (SH)** coefficients.

The final color $c$ is evaluated based on the camera's current viewing direction $d$:

$c = \sum_{l=0}^{L} \sum_{m=-l}^{l} c_{l}^{m} Y_{l}^{m}(d)$

Where $Y_{l}^{m}$ are the SH basis functions and $c_{l}^{m}$ are the learned coefficients. In the code, you will see a degree parameter (usually 3), meaning each Gaussian stores up to 16 SH coefficients per color channel (48 floats total).

## 3. Projection: 3D to 2D Screen Space 

To render the scene, the 3D Gaussians must be projected onto a 2D image plane. Given a camera viewing transformation matrix $W$, we project the 3D covariance matrix $\Sigma$ into a 2D covariance matrix $\Sigma'$. 

Because perspective projection is non-linear, the CUDA kernels use an affine approximation with the Jacobian matrix $J$:

$\Sigma' = J W \Sigma W^T J^T$

**Code Translation:** In `forward.cu`, this specific formula flattens the 3D ellipsoid into a 2D ellipse (the "splat") oriented for the camera's perspective. The upper-left 2x2 elements of the resulting matrix define the 2D screen-space shape.

## 4. The CUDA Rasterization Pipeline

The performance breakthrough of this engine lies in avoiding per-pixel neural network evaluations. The math is mapped directly to a highly parallel GPU pipeline.

1. **Frustum Culling:** A compute shader checks the projected mean $\mu$ and bounding box of each Gaussian. If it falls outside the camera's frustum, it is discarded for this frame.
2. **Depth Sorting (Radix Sort):** To correctly apply alpha-blending, the Gaussians must be rendered back-to-front (or front-to-back with early stopping). The engine uses a highly optimized CUB Radix Sort to order them based on their distance from the camera screen plane.
3. **Tile-Based Rasterization:** The image is divided into 16x16 pixel tiles. Each CUDA thread block is assigned a tile.
4. **Shared Memory Loading:** Thread blocks load the sorted Gaussians that overlap their specific 16x16 tile into fast GPU shared memory.
5. **Alpha Compositing:** Each thread calculates the final pixel color $C$ by evaluating the sorted 2D splats:

$C = \sum_{i=1}^{N} c_i \alpha_i \prod_{j=1}^{i-1} (1 - \alpha_j)$

Here, $\alpha_i$ is the opacity multiplied by the 2D Gaussian's spatial falloff. **Crucially, the code implements early stopping:** once the accumulated opacity for a pixel reaches $\approx 1$, the thread terminates, saving massive amounts of compute.

## 5. Optimization & Backpropagation 

Because the entire projection and rendering equation is differentiable, the error between the rendered image and the ground-truth training images can be backpropagated. 

The `backward.cu` kernel computes the gradients of the loss with respect to the 2D means, colors, and opacities, and chains them backward through the Jacobian $J$ to update the original 3D position $\mu$, quaternion $R$, scale $S$, and SH coefficients of every Gaussian.
