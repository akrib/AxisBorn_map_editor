# AxisBorn – Éditeur de carte

Projet Godot 4.3+ pour créer et éditer des cartes de type FFT (Final Fantasy Tactics).

## Installation

1. Ouvre Godot 4.3 ou supérieur
2. Importe ce projet (`project.godot`)
3. Lance le projet (F5)

## Structure des fichiers

```
map_editor/
├── main.gd                    ← Point d'entrée
├── scripts/
│   ├── map_data.gd            ← Modèle de données (grille, tuiles, cubes, faces)
│   ├── mesh_builder.gd        ← Construction des meshes ArrayMesh
│   ├── editor_3d.gd           ← Scène 3D, caméra, picking, outils
│   └── editor_ui.gd           ← Toute l'interface (top/bottom/side bar)
└── assets/textures/           ← Place tes atlas PNG ici (optionnel, auto-scanné)
```

## Utilisation

### Démarrage
Au lancement, une fenêtre demande la taille de la carte (largeur × hauteur en tuiles).

### Navigation 3D
- **Clic milieu** : orbiter la caméra
- **Shift + Clic milieu** : paner
- **Molette** : zoom

### Outils (barre du haut)

| Icône | Outil | Comportement |
|-------|-------|-------------|
| ⊕ | **4 Coins partagés** | Clique entre des tuiles → sélectionne tous les coins contigus. +/- ajuste la hauteur de tous simultanément. |
| ↕ | **Hauteur de face** | Clique sur une face → sélectionne cette face. +/- ajuste les coins supérieurs de la face. |
| 🖌 | **Texture** | Sélectionne une texture dans la barre latérale, puis clique sur une face pour l'appliquer. |
| ◉ | **Coin unique** | Clique sur une tuile → sélectionne le coin le plus proche. +/- ajuste ce coin seul. |

### Subdivision
- **⊞ Subdiviser** : divise une tuile sélectionnée en 4 sous-cubes (une fois seulement). 
  Utile pour les escaliers ou détails fins.
- **⊟ Fusionner** : re-fusionne les 4 sous-cubes en une tuile.

### Textures
1. Clique **📂 Importer atlas…** dans la barre latérale
2. Sélectionne un ou plusieurs PNG d'atlas (grille de textures)
3. Règle la taille de cellule (ex: 32px pour un atlas 256×256 = 8×8 cellules)
4. Clique une cellule dans la barre latérale → devient la texture active
5. Active l'outil **Texture** (🖌) → clique sur une face pour l'appliquer
6. Ajuste le **UV Scale** dans la barre du bas pour moduler la répétition

*Tu peux aussi placer des PNG dans `assets/textures/` : ils seront scannés au démarrage.*

### Sauvegarde / Chargement
- **💾 Sauver** → JSON (format interne)
- **📂 Ouvrir** → Charge un JSON précédent
- Le JSON peut aussi être exporté vers TerrainModule3D via `editor_3d.export_to_json_map()`

### Mode Test
Active **Mode Test** dans la barre du haut pour masquer les cubes éditeur
et prévisualiser le résultat tel qu'il apparaîtrait en jeu avec TerrainModule3D.

## Format des données (MapData)

```
TerrainTileData
 ├── subdivided: bool
 └── cubes[]: CubeData
      ├── corners[4]: float  ← Y des 4 coins supérieurs [NW, NE, SE, SW]
      ├── base_y: float       ← Y du bas du cube
      └── face_configs[6]: FaceConfig
           ├── atlas_path: String
           ├── atlas_col/row: int
           ├── cell_size: int (pixels)
           └── uv_scale: float
```

## Intégration avec TerrainModule3D

La fonction `editor_3d.export_to_json_map()` retourne un Dictionary au format
attendu par `TerrainModule3D.load_custom()`. Tu peux l'utiliser pour peupler
directement le module terrain du jeu.
