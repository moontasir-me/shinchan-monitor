# Artwork generation

Built-in imagegen tool, transparent RGBA output, saved as project assets. No generation or asset download occurs at runtime.

## Sprite sheet: Source/Assets/spritesheet.png

Prompt: “Use case: stylized-concept. Asset type: retro 32-bit pixel-art desktop pet animation sprite sheet. Primary request: Tintin sitting and using a laptop. Recognizable young adventurer with orange quiff, round face, blue sweater over white collar, brown trousers, brown shoes, a small gray laptop on his lap. Cute friendly compact full-body proportions, clean colorful video-game pixel art with crisp square pixels. Exactly 4 columns and 4 rows of equal-sized cells on a square 1024 by 1024 genuinely transparent background. Same character scale, same centered seated pose and laptop baseline in every cell; plenty of transparent padding, no overlap between cells. First row: four idle frames including a blink. Second row: four typing frames with alternating hands. Third row: four waving frames while laptop remains on lap. Fourth row: four surprised attentive alert frames with raised eyebrows. Laptop visible in all 16 cells. No other characters, no text, no grid lines, no borders, no watermark, no scenery.”

The service returned a 1254×1254 RGBA image; the renderer reads the actual dimensions and divides it into four rows and columns.

## App icon: Source/Assets/AppIcon.png

Prompt: “Use case: stylized-concept. Asset type: app icon illustration with genuine transparent background. One full-body cute Tintin, orange quiff, blue sweater with white collar, brown trousers and brown shoes, seated cross-legged using a small gray laptop on his lap. Front three-quarter view, cheerful face. Polished retro 32-bit video-game pixel art, crisp visible pixels and dark outline. One character centered, comfortable transparent padding, square canvas. No other people, no dog, no background, no text or watermark.”
