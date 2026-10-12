import React, {memo, useState} from 'react';
import {StyleSheet, Text, TouchableOpacity} from 'react-native';

export const TVButton = memo(function TVButton({label, onPress, preferred = false, selected = false}: {
  label: string; onPress: () => void; preferred?: boolean; selected?: boolean;
}) {
  const [focused, setFocused] = useState(false);
  return <TouchableOpacity accessibilityRole="button" accessibilityLabel={label}
    hasTVPreferredFocus={preferred} onFocus={() => setFocused(true)} onBlur={() => setFocused(false)}
    onPress={onPress} activeOpacity={1} style={[styles.button, selected && styles.selected, focused && styles.focused]}>
    <Text numberOfLines={2} style={styles.label}>{label}</Text>
  </TouchableOpacity>;
});

const styles = StyleSheet.create({
  button: {padding: 18, margin: 6, backgroundColor: '#172233', borderWidth: 3, borderColor: '#172233', borderRadius: 12},
  selected: {backgroundColor: '#233d52', borderColor: '#3a7185'},
  focused: {borderColor: '#5eead4', backgroundColor: '#254559'},
  label: {color: '#f8fafc', fontSize: 22},
});
