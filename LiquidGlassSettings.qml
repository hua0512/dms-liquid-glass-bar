import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "liquidGlassBar"

    StyledText {
        width: parent.width
        text: "Liquid Glass Bar"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Theme.fontWeightMedium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Renders the wallpaper behind the bar through a refractive glass shader. Works best with the bar's own transparency at 0 and its compositor blur turned off."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ToggleSetting {
        settingKey: "adaptiveForeground"
        label: "Adaptive text colour"
        description: "Like the macOS menu bar: the bar's text, icons and pills turn light over a dark wallpaper and dark over a light one, whatever the light/dark mode."
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "shape"
        label: "Shape"
        description: "Capsule gives the glass fully rounded ends inside the bar; Bar follows the bar's own corners."
        options: [
            {
                "label": "Capsule",
                "value": "capsule"
            },
            {
                "label": "Bar",
                "value": "bar"
            }
        ]
        defaultValue: "capsule"
    }

    SliderSetting {
        settingKey: "refraction"
        label: "Refraction"
        description: "How strongly the narrow rounded rim bends the wallpaper. 0 is flat glass."
        defaultValue: 70
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SelectionSetting {
        settingKey: "lensMode"
        label: "Edge lensing"
        description: "Magnify bends light like a real convex rim, enlarging what lies just inside the edge. Wrap pulls what lies just beyond the edge into the rim."
        options: [
            {
                "label": "Magnify",
                "value": "magnify"
            },
            {
                "label": "Wrap",
                "value": "wrap"
            }
        ]
        defaultValue: "magnify"
    }

    SliderSetting {
        settingKey: "rimHighlight"
        label: "Rim highlight"
        description: "Specular edge light, brightest along the top edge."
        defaultValue: 70
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "frost"
        label: "Frost"
        description: "Blur of the wallpaper seen through the glass."
        defaultValue: 50
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "saturation"
        label: "Saturation"
        description: "Colour boost of what is seen through the glass. 100 leaves it unchanged."
        defaultValue: 108
        minimum: 50
        maximum: 250
        unit: "%"
    }

    SliderSetting {
        settingKey: "dispersion"
        label: "Chromatic fringe"
        description: "Colour separation in the refracted rim."
        defaultValue: 15
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SelectionSetting {
        settingKey: "tintMode"
        label: "Tint colour"
        description: "Auto uses white in light mode and near-black in dark mode."
        options: [
            {
                "label": "Auto",
                "value": "auto"
            },
            {
                "label": "White",
                "value": "white"
            },
            {
                "label": "Black",
                "value": "black"
            },
            {
                "label": "Surface",
                "value": "surface"
            },
            {
                "label": "Primary",
                "value": "primary"
            }
        ]
        defaultValue: "auto"
    }

    SliderSetting {
        settingKey: "tintStrength"
        label: "Tint strength"
        defaultValue: 0
        minimum: 0
        maximum: 60
        unit: "%"
    }

    SliderSetting {
        settingKey: "contrast"
        label: "Legibility scrim"
        description: "A faint shade (at most about 6%) behind the text, only where the wallpaper fights the text colour."
        defaultValue: 50
        minimum: 0
        maximum: 100
        unit: "%"
    }

    SliderSetting {
        settingKey: "shadow"
        label: "Drop shadow"
        defaultValue: 50
        minimum: 0
        maximum: 100
        unit: "%"
    }
}
