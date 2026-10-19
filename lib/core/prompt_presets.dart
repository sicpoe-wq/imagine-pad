class StylePreset {
  final String id;
  final String label;
  final String suffix;
  const StylePreset(this.id, this.label, this.suffix);
}

const stylePresets = <StylePreset>[
  StylePreset('none', 'None', ''),
  StylePreset(
    'photo',
    'Photo',
    'photorealistic, natural lighting, sharp focus, 35mm photo, highly detailed',
  ),
  StylePreset(
    'cinematic',
    'Cinematic',
    'cinematic still, dramatic lighting, shallow depth of field, film grain',
  ),
  StylePreset(
    'anime',
    'Anime',
    'anime style, clean line art, vibrant cel shading',
  ),
  StylePreset(
    '3d',
    '3D render',
    '3D render, octane render, soft global illumination, high detail',
  ),
  StylePreset(
    'painting',
    'Oil painting',
    'oil painting on canvas, visible brush strokes, rich colors',
  ),
  StylePreset(
    'watercolor',
    'Watercolor',
    'watercolor painting, soft washes, paper texture',
  ),
  StylePreset(
    'pixel',
    'Pixel art',
    'pixel art, 16-bit retro game style, crisp pixels',
  ),
  StylePreset(
    'comic',
    'Comic',
    'comic book illustration, bold ink outlines, halftone shading',
  ),
  StylePreset(
    'sketch',
    'Sketch',
    'pencil sketch, graphite shading, hand drawn',
  ),
  StylePreset(
    'cyberpunk',
    'Cyberpunk',
    'cyberpunk, neon lights, rainy night, futuristic',
  ),
  StylePreset(
    'lowpoly',
    'Low poly',
    'low poly geometric art, flat shaded facets',
  ),
];

StylePreset presetById(String? id) => stylePresets.firstWhere(
  (p) => p.id == id,
  orElse: () => stylePresets.first,
);

/// Base prompt + style suffix.
String composePrompt(String base, StylePreset style) {
  final b = base.trim();
  if (style.suffix.isEmpty || b.isEmpty) return b;
  final sep = b.endsWith(',') || b.endsWith('.') ? ' ' : ', ';
  return '$b$sep${style.suffix}';
}

const examplePrompts = <String>[
  'A Starship rocket lifting off at sunset over the Texas coast',
  'A friendly humanoid robot making pizza in a cozy kitchen',
  'An astronaut riding a horse on Mars, golden hour',
  'A cozy cabin in snowy mountains under the northern lights',
  'A futuristic city with flying cars and green rooftops',
  'A red panda reading a book in a library, soft light',
  'A lighthouse on a cliff during a stormy night',
  'A koi pond in a Japanese garden in autumn',
];
