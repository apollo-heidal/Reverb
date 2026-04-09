#!/usr/bin/env bash
set -euo pipefail

prompt="$(cat)"
feature_id="$(printf '%s\n' "$prompt" | sed -n 's/^Feature ID: //p' | head -n1)"
target_file="lib/reverb_demo_app/simple_features.ex"

if [[ ! -f "$target_file" ]]; then
  echo "demo agent expected $target_file in the workspace"
  exit 1
fi

case "$feature_id" in
  demo-double)
    perl -0pi -e 's/def double\(_n\), do: :not_implemented/def double(n), do: n * 2/' "$target_file"
    ;;
  demo-reverse-words)
    perl -0pi -e 's/def reverse_words\(_value\), do: :not_implemented/def reverse_words(value), do: value |> String.split(" ", trim: true) |> Enum.reverse() |> Enum.join(" ")/' "$target_file"
    ;;
  demo-sum-even)
    perl -0pi -e 's/def sum_even\(_values\), do: :not_implemented/def sum_even(values), do: values |> Enum.filter\(&\(rem\(&1, 2\) == 0\)\) |> Enum.sum\(\)/' "$target_file"
    ;;
  *)
    echo "unsupported or missing feature id: ${feature_id:-<none>}"
    exit 1
    ;;
esac

echo "implemented ${feature_id}"
