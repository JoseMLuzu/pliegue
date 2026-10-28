# Release Preparation

The generated app is a local development build. No Mac App Store submission, pricing, certificate change, agreement acceptance, or financial setup has been performed. The proposed price is USD 4.99, paid once.

Before submission:

1. Test native HEVC, AAC, and ALAC on physical Macs: audio passthrough, sample fidelity, portrait orientation, variable frame rates, long media, no savings, cancellation, and low disk space. Encoder-unavailable test skips are not successful codec tests. Test JPEG/PNG/HEIC/TIFF conversions with orientation, transparency, ICC profiles, and unsupported HDR/depth images. Exercise GLB validation and complete 3D project ZIPs, including linked textures and empty folders.
2. Test the signed sandbox app's file/folder open panels, save panels, Finder drops, output replacement, and quitting during each operation. Verify included folder assets can be read and archives must save outside their source folders. Validate Apple Silicon and Intel before advertising support for either architecture.
3. Register the final bundle identifier and developer team; replace ad-hoc local signing with distribution signing and provisioning. Archive and validate in Xcode. No distribution credentials are stored here.
4. Finalize artwork, screenshots, support URL, published privacy policy, and privacy manifest audit. Clearly disclose lossy choices, lossless decoded-media versus exact-file preservation, supported format limits, and conservative GLB optimization. Do not promise smaller output for every file.
5. Configure the paid listing, regional prices, agreements, tax, and banking details in the publisher's App Store Connect account.
6. Upload and submit the validated build. Apple controls review approval and availability.
